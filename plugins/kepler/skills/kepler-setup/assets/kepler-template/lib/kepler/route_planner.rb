# frozen_string_literal: true

require_relative "config"
require_relative "bridge_store"
require_relative "architecture_map_store"

module Kepler
  class RoutePlanner
    WORK_TYPES = %w[read_only implementation review artifact runtime_validation coordination].freeze

    def initialize(config)
      @config = config
    end

    def plan(workspace:, domain:, work_type:)
      normalized_type = work_type.to_s.tr("-", "_")
      raise UsageError, "invalid work type" unless WORK_TYPES.include?(normalized_type)
      architecture = ArchitectureMapStore.new(@config).load
      workspace_entry = architecture.fetch("workspaces")[workspace.to_s]
      raise ValidationError, "unknown workspace: #{workspace}" unless workspace_entry
      raise ValidationError, "unknown domain: #{workspace}.#{domain}" unless workspace_entry.fetch("domains").key?(domain.to_s)

      logical_key = workspace_entry.fetch("codex_project")
      project_path = File.realpath(workspace_entry.fetch("project_path"))
      verification = @config.project_verification(logical_key: logical_key, expected_path: project_path)
      raise ValidationError, "selected project #{logical_key} is not exactly verified: #{verification['status']}" unless verification["status"] == "verified"
      unless verification["runtime_project_id"] == workspace_entry.fetch("runtime_project_id")
        raise ValidationError, "ArchitectureMap runtime project ID conflicts with the verified selected project"
      end

      project_record = @config.project_verifications.fetch(logical_key)
      mode = mode_for(normalized_type, project_record)
      bridge_handoff = optional_bridge_handoff(workspace_entry)
      dispatcher = @config.routing.fetch("dispatcher_runtime")
      planner = @config.routing.fetch("planner_runtime")
      {
        "schema_version" => "kepler.route-plan/v2",
        "plan_read_only" => true,
        "workspace" => workspace.to_s,
        "domain" => domain.to_s,
        "work_type" => normalized_type,
        "logical_project_key" => logical_key,
        "runtime_project_id" => verification.fetch("runtime_project_id"),
        "project_path" => project_path,
        "mode" => mode,
        "dispatch_required" => normalized_type != "read_only",
        "dispatch_ready" => true,
        "stop_after_dispatch" => true,
        "planner_runtime" => runtime_contract(planner),
        "dispatcher_runtime" => runtime_contract(dispatcher),
        "worker_runtime" => {
          "role" => "ordinary_codex_worker",
          "model" => "user_or_project_configured",
          "directly_accessible" => true
        },
        "bridge_handoff" => bridge_handoff,
        "context_policy" => {
          "context_pack_is_initial_context" => true,
          "context_pack_is_exclusive_boundary" => false,
          "transcript_sync" => false,
          "completion_source" => "validated_worker_result"
        },
        "task_resolution" => {
          "search" => "recent_tasks_in_exact_project",
          "matching_action" => "resume",
          "no_match_action" => "create",
          "persistent" => true
        },
        "dispatch_receipt" => {
          "required" => true,
          "fields" => %w[
            logical_project_key runtime_project_id project_path task_id mode
            requested_model effective_model requested_thinking effective_thinking
            authorization_boundary creation_method bootstrap_schema_version
            bootstrap_task_id configuration_verification_schema_version
            configuration_verified configuration_verified_task_id
            configuration_verified_before_prompt configuration_mode
            permission_profile sandbox_mode approval_policy
          ],
          "monitoring_permitted" => false
        },
        "authorization_boundary" => "Explicit approval is required for commit, push, pull requests or comments, publication, deployment, shared environment mutation, external communication, compliance submission, risk acceptance, and closure claims.",
        "steps" => [
          "Verify the selected saved project by opaque runtime ID and exact normalized path.",
          "Search recent tasks in that exact project and resume only an objective match.",
          "Otherwise bootstrap an empty permission-preserving Local task with model #{dispatcher.fetch('model')} and thinking #{dispatcher.fetch('thinking')}; never directly create a prompted worker.",
          "For Worktree mode, hand off the empty task, then verify the exact final task and effective configuration before its prompt.",
          "Send the ContextPack as non-exclusive initial context and request a structured WorkerResult.",
          "Record bootstrap and final-task verification evidence plus requested and effective runtime fields in the DispatchReceipt.",
          "Return the receipt immediately; do not inspect artifacts, poll, wait, or monitor."
        ]
      }
    rescue Errno::ENOENT, Errno::ELOOP => e
      raise ValidationError, "selected project path cannot be resolved safely: #{e.message}"
    end

    private

    def runtime_contract(value)
      {
        "role" => value.fetch("role"),
        "requested_model" => value.fetch("model"),
        "requested_thinking" => value.fetch("thinking"),
        "effective_model" => nil,
        "effective_thinking" => nil,
        "evidence_source" => "task_create_or_message_receipt"
      }
    end

    def mode_for(work_type, project_record)
      return "local" if work_type == "read_only" || work_type == "runtime_validation"
      project_record["is_git_repository"] == true ? "worktree" : "local"
    end

    def optional_bridge_handoff(workspace_entry)
      repository_id = workspace_entry["bridge_repository_id"]
      return {
        "required" => false,
        "status" => "not_configured",
        "policy" => "dispatch_without_bridge"
      } unless Support.present?(repository_id)

      repository = @config.repository(repository_id)
      raise ValidationError, "configured bridge repository is unknown: #{repository_id}" unless repository
      store = BridgeStore.new(@config)
      mode = repository.fetch("bridge_mode")
      profile = repository.fetch("bridge_profile")
      bridge_plan = store.plan(repository_id: repository_id, mode: mode, profile: profile)
      unless bridge_plan["desired_state"] == "valid" && bridge_plan.fetch("blockers").empty?
        details = bridge_plan.fetch("blockers")
        details = ["bridge is not installed"] if details.empty?
        raise ValidationError, "configured bridge must be valid before dispatch: #{details.join('; ')}"
      end
      record = store.record_for(repository_id)
      {
        "required" => true,
        "status" => "verified",
        "repository_id" => repository_id,
        "mode" => mode,
        "profile" => profile,
        "version" => record.fetch("version"),
        "target" => record.fetch("target"),
        "sha256" => record.fetch("sha256")
      }
    end
  end
end

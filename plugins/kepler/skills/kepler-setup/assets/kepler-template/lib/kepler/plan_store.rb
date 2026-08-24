# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "context_compiler"
require_relative "contracts"

module Kepler
  class PlanStore
    def initialize(config)
      @config = config
    end

    def apply(source_path, expected_revision: nil)
      candidate = Contracts.plan!(Support.load_data(source_path))
      validate_topology!(candidate)
      id = candidate.dig("metadata", "id")
      with_lock(id) do
        current = File.file?(plan_path(id)) ? load(id) : nil
        if expected_revision && (!current || current.dig("metadata", "revision").to_i != expected_revision.to_i)
          actual = current&.dig("metadata", "revision") || "none"
          raise ValidationError, "stale Plan revision: expected #{expected_revision}, current #{actual}"
        end
        if current && candidate.dig("metadata", "revision").to_i <= current.dig("metadata", "revision").to_i
          raise ValidationError, "Plan revision must increase monotonically"
        end
        retried_units = current ? carry_forward_execution_state!(current, candidate) : []
        normalize_readiness!(candidate)
        candidate["metadata"]["change_summary"] = revision_changes(current, candidate, retried_units)
        candidate["metadata"]["updated_at"] = Time.now.utc.iso8601
        candidate["metadata"]["created_at"] ||= current&.dig("metadata", "created_at") || candidate.dig("metadata", "updated_at")
        Support.atomic_yaml(plan_path(id), candidate)
        Support.atomic_write(File.join(@config.plan_dir, "current"), "#{id}\n")
        summary(candidate).merge("status" => current ? "revised" : "created")
      end
    end

    def load(id = nil)
      id ||= current_id
      Support.validate_identifier!(id, label: "Plan id")
      Contracts.plan!(Support.load_data(plan_path(id)))
    end

    def summary(plan)
      states = plan["units"].group_by { |unit| state(unit) }.transform_values(&:length)
      statuses = plan["units"].map { |unit| unit_summary(unit) }
      {
        "plan_id" => plan.dig("metadata", "id"),
        "revision" => plan.dig("metadata", "revision"),
        "change_summary" => Array(plan.dig("metadata", "change_summary")),
        "state" => plan.dig("status", "state"),
        "units" => states,
        "unit_status" => statuses,
        "ready_units" => ready_units(plan).map { |unit| unit["id"] },
        "token_efficiency" => token_efficiency(statuses)
      }
    end

    def prepare_dispatch(id:, revision:, unit_id: nil, budget: ContextCompiler::DEFAULT_BUDGET)
      plan = load(id)
      assert_revision!(plan, revision)
      candidates = ready_units(plan)
      candidates.select! { |unit| unit["id"] == unit_id } if unit_id
      raise ValidationError, "no ready Plan units match the dispatch request" if candidates.empty?
      envelopes = candidates.map do |unit|
        target = dispatch_target(unit)
        pack, path = ContextCompiler.new(@config).compile(plan: plan, unit: unit, budget: budget)
        {
          "plan_id" => id,
          "plan_revision" => revision.to_i,
          "unit_id" => unit["id"],
          "codex_project" => pack.dig("scope", "codex_project"),
          "paths" => pack.dig("scope", "paths"),
          "runtime_project_id" => target["runtime_project_id"],
          "project_path" => target["project_path"],
          "context_pack_id" => pack.dig("metadata", "id"),
          "context_pack_path" => Support.relative_path(@config.root, path),
          "receipt_and_stop" => true
        }
      end
      { "api_version" => Contracts::API_VERSION, "kind" => "DispatchEnvelopeList", "plan_id" => id, "plan_revision" => revision.to_i, "units" => envelopes }
    end

    def record_dispatch(id:, revision:, unit_id:, receipt_path:)
      receipt = Contracts.dispatch_receipt!(Support.load_data(receipt_path))
      update(id, revision) do |plan|
        unit = find_unit(plan, unit_id)
        raise ValidationError, "unit #{unit_id} is not ready" unless state(unit) == "ready"
        target = dispatch_target(unit)
        unless receipt["runtime_project_id"] == target["runtime_project_id"]
          raise ValidationError, "dispatch receipt runtime project does not match verified target"
        end
        begin
          exact_path = File.realpath(receipt["project_path"]) == File.realpath(target["project_path"])
        rescue Errno::ENOENT, Errno::ELOOP
          exact_path = false
        end
        raise ValidationError, "dispatch receipt path does not match verified target" unless exact_path
        begin
          control_owner = File.realpath(receipt["dispatch_owner_project_path"]) == File.realpath(@config.root)
        rescue Errno::ENOENT, Errno::ELOOP
          control_owner = false
        end
        raise ValidationError, "dispatch receipt owner is not the current control project" unless control_owner
        %w[project_association_before project_association_after].each do |field|
          association = receipt.fetch(field)
          unless association["runtime_project_id"] == target["runtime_project_id"]
            raise ValidationError, "dispatch receipt #{field} project ID does not match verified target"
          end
          begin
            association_path = File.realpath(association["project_path"]) == File.realpath(target["project_path"])
          rescue Errno::ENOENT, Errno::ELOOP
            association_path = false
          end
          raise ValidationError, "dispatch receipt #{field} path does not match verified target" unless association_path
        end
        before_cwd = receipt.dig("project_association_before", "task_cwd")
        after_cwd = receipt.dig("project_association_after", "task_cwd")
        begin
          stable_task_cwd = File.realpath(before_cwd) == File.realpath(after_cwd)
        rescue Errno::ENOENT, Errno::ELOOP, TypeError
          stable_task_cwd = false
        end
        raise ValidationError, "dispatch receipt worker task path changed during delivery" unless stable_task_cwd
        if receipt["mode"] == "local"
          unless File.realpath(before_cwd) == File.realpath(target["project_path"])
            raise ValidationError, "dispatch receipt Local task path does not match verified target"
          end
        elsif receipt["mode"] == "worktree"
          unless registered_non_primary_worktree?(target["project_path"], before_cwd)
            raise ValidationError, "dispatch receipt Worktree task path is not a registered non-primary checkout of the verified target"
          end
        end
        context_path = File.join(@config.context_pack_dir, "#{receipt['context_pack_id']}.yaml")
        context = Contracts.context_pack!(Support.load_data(context_path))
        expected_context_id = "ctx-#{id}-#{unit_id}-r#{revision}"
        unless receipt["context_pack_id"] == expected_context_id && context.dig("metadata", "id") == expected_context_id
          raise ValidationError, "dispatch receipt ContextPack does not match the exact Plan unit revision"
        end
        unless receipt["context_pack_estimated_tokens"].to_i == context.dig("metadata", "estimated_tokens").to_i &&
               receipt["context_pack_token_budget"].to_i == context.dig("metadata", "token_budget").to_i
          raise ValidationError, "dispatch receipt ContextPack token accounting does not match the compiled artifact"
        end
        destination = File.join(@config.dispatch_receipt_dir, "#{id}-r#{revision}-#{unit_id}.yaml")
        Support.atomic_yaml(destination, receipt.merge("plan_id" => id, "plan_revision" => revision.to_i, "unit_id" => unit_id))
        unit["status"] = { "state" => "dispatched", "updated_at" => Time.now.utc.iso8601 }
        unit["dispatch_receipt"] = Support.relative_path(@config.root, destination)
        plan["status"] = { "state" => "dispatched" }
      end
    end

    def prepare_cleanup(id:, revision:, unit_id: nil, preserve_worktrees: false)
      plan = load(id)
      assert_revision!(plan, revision)
      candidates = unit_id ? [find_unit(plan, unit_id)] : plan["units"]
      already_cleaned = candidates.select { |unit| Support.present?(unit["cleanup_receipt"]) }
      if unit_id && !already_cleaned.empty?
        raise ValidationError, "unit #{unit_id} already has a recorded CleanupReceipt"
      end
      candidates -= already_cleaned
      envelopes = candidates.map do |unit|
        target = cleanup_target!(plan, unit)
        {
          "plan_id" => id,
          "plan_revision" => revision.to_i,
          "unit_id" => unit["id"],
          "task_id" => target.fetch("task_id"),
          "runtime_project_id" => target.fetch("runtime_project_id"),
          "project_path" => target.fetch("project_path"),
          "worker_cwd" => target.fetch("worker_cwd"),
          "mode" => target.fetch("mode"),
          "herdr_attachment" => target.fetch("herdr_attachment"),
          "requested_action" => cleanup_action(target, preserve_worktrees: preserve_worktrees),
          "receipt_and_stop" => true
        }
      end
      raise ValidationError, "no terminal Plan units match the cleanup request" if envelopes.empty?

      {
        "api_version" => Contracts::API_VERSION,
        "kind" => "CleanupEnvelopeList",
        "plan_id" => id,
        "plan_revision" => revision.to_i,
        "units" => envelopes
      }
    end

    def record_cleanup(id:, revision:, unit_id:, receipt_path:)
      raw = Support.load_data(receipt_path)
      with_lock(id) do
        plan = load(id)
        assert_revision!(plan, revision)
        unit = find_unit(plan, unit_id)
        target = cleanup_target!(plan, unit)
        receipt = normalize_cleanup_receipt(raw).merge(
          "api_version" => Contracts::API_VERSION,
          "kind" => "CleanupReceipt",
          "plan_id" => id,
          "plan_revision" => revision.to_i,
          "unit_id" => unit_id
        )
        validate_cleanup_plan_fields!(raw, id: id, revision: revision, unit_id: unit_id)
        receipt = Contracts.cleanup_receipt!(receipt)
        validate_cleanup_matches_target!(receipt, target)
        action = cleanup_action(target, preserve_worktrees: !receipt["remove_worktree_requested"])
        validate_cleanup_action!(receipt, action)
        destination = File.join(@config.cleanup_receipt_dir, "#{id}-r#{revision}-#{unit_id}.yaml")
        if File.file?(destination)
          existing = Contracts.cleanup_receipt!(Support.load_data(destination))
          unless existing == receipt
            raise ValidationError, "unit #{unit_id} already has a different CleanupReceipt"
          end
          return summary(plan).merge("cleanup_recording" => "unchanged")
        end

        FileUtils.mkdir_p(@config.cleanup_receipt_dir)
        Support.atomic_yaml(destination, receipt)
        unit["cleanup_receipt"] = Support.relative_path(@config.root, destination)
        plan["metadata"]["updated_at"] = Time.now.utc.iso8601
        Support.atomic_yaml(plan_path(id), plan)
        summary(plan).merge("cleanup_recording" => "recorded")
      end
    end

    def ingest_result(source_path)
      result = Contracts.worker_result!(Support.load_data(source_path))
      id = result.dig("metadata", "plan_id")
      dispatch_revision = result.dig("metadata", "plan_revision")
      unit_id = result.dig("metadata", "unit_id")
      with_lock(id) do
        plan = load(id)
        unit = find_unit(plan, unit_id)
        if Support.present?(unit["worker_result"])
          existing = Contracts.worker_result!(
            Support.load_data(File.join(@config.root, unit["worker_result"]))
          )
          unless existing == result
            raise ValidationError, "unit #{unit_id} already has a different WorkerResult"
          end
          return summary(plan).merge("result_ingestion" => "unchanged")
        end
        raise ValidationError, "unit #{unit_id} has not been dispatched" unless %w[dispatched working blocked].include?(state(unit))
        receipt = load_optional(unit["dispatch_receipt"])
        unless receipt && receipt["plan_revision"].to_i == dispatch_revision.to_i
          raise ValidationError, "WorkerResult Plan revision does not match the unit dispatch receipt"
        end
        destination = File.join(@config.worker_result_dir, "#{result.dig('metadata', 'id')}.yaml")
        Support.atomic_yaml(destination, result)
        unit["worker_result"] = Support.relative_path(@config.root, destination)
        unit["status"] = { "state" => result["status"], "updated_at" => Time.now.utc.iso8601 }
        normalize_readiness!(plan)
        plan["metadata"]["updated_at"] = Time.now.utc.iso8601
        Support.atomic_yaml(plan_path(id), plan)
        summary(plan).merge("result_ingestion" => "ingested")
      end
    end

    private

    def validate_topology!(plan)
      architecture = ArchitectureMapStore.new(@config).load
      plan["units"].each do |unit|
        workspace = architecture["workspaces"][unit["workspace"]]
        raise ValidationError, "Plan unit #{unit['id']} references unknown workspace #{unit['workspace']}" unless workspace
        domain = workspace["domains"][unit["domain"]]
        raise ValidationError, "Plan unit #{unit['id']} references unknown domain #{unit['workspace']}.#{unit['domain']}" unless domain
        domain_paths = Array(domain["paths"])
        Array(unit["paths"]).each do |unit_path|
          covered = domain_paths.any? do |domain_path|
            unit_path == domain_path || unit_path.start_with?("#{domain_path}/")
          end
          raise ValidationError, "Plan unit #{unit['id']} path is outside confirmed domain #{unit_path}" unless covered
        end
      end
    end

    def carry_forward_execution_state!(current, candidate)
      retried_units = []
      current_units = current["units"].each_with_object({}) { |unit, memo| memo[unit["id"]] = unit }
      candidate_ids = candidate["units"].map { |unit| unit["id"] }
      removed_bound = current["units"].select do |unit|
        !candidate_ids.include?(unit["id"]) &&
          %w[dispatched working blocked completed failed].include?(state(unit))
      end
      unless removed_bound.empty?
        raise ValidationError,
              "Plan revision cannot remove execution-bound units: #{removed_bound.map { |unit| unit['id'] }.join(', ')}"
      end

      candidate["units"].each do |unit|
        previous = current_units[unit["id"]]
        next unless previous
        previous_state = state(previous)
        next unless %w[dispatched working blocked completed failed].include?(previous_state)

        if unit.delete("retry") == true
          unless %w[blocked failed].include?(previous_state)
            raise ValidationError, "unit #{unit['id']} can retry only from blocked or failed"
          end
          unit.delete("dispatch_receipt")
          unit.delete("worker_result")
          unit.delete("cleanup_receipt")
          unit["status"] = { "state" => "planned" }
          retried_units << unit["id"]
          next
        end

        unless unit_spec(previous) == unit_spec(unit)
          raise ValidationError,
                "Plan revision cannot change execution-bound unit #{unit['id']} without an explicit blocked/failed retry"
        end
        %w[status dispatch_receipt worker_result cleanup_receipt].each do |key|
          unit[key] = previous[key] if previous.key?(key)
        end
      end
      retried_units
    end

    def unit_spec(unit)
      unit.reject do |key, _value|
        %w[status dispatch_receipt worker_result cleanup_receipt retry].include?(key)
      end
    end

    def cleanup_target!(plan, unit)
      result = load_optional(unit["worker_result"])
      receipt = load_optional(unit["dispatch_receipt"])
      raise ValidationError, "unit #{unit['id']} is active or incomplete and cannot be cleaned up" unless %w[completed blocked failed].include?(state(unit))
      raise ValidationError, "unit #{unit['id']} requires a validated WorkerResult before cleanup" unless result
      Contracts.worker_result!(result)
      unless result.dig("metadata", "plan_id") == plan.dig("metadata", "id") &&
             result.dig("metadata", "plan_revision").to_i == plan.dig("metadata", "revision").to_i &&
             result.dig("metadata", "unit_id") == unit["id"] &&
             result["status"] == state(unit)
        raise ValidationError, "unit #{unit['id']} WorkerResult does not match the current Plan terminal state"
      end
      raise ValidationError, "unit #{unit['id']} requires a validated DispatchReceipt before cleanup" unless receipt
      Contracts.dispatch_receipt!(receipt)
      attachment = receipt["herdr_attachment"]
      raise ValidationError, "unit #{unit['id']} has no owned Herdr attachment to clean up" unless attachment
      worker_cwd = receipt.dig("project_association_after", "task_cwd")
      Contracts.herdr_attachment!(attachment, task_id: receipt["task_id"], worker_cwd: worker_cwd)
      {
        "task_id" => receipt.fetch("task_id"),
        "runtime_project_id" => receipt.fetch("runtime_project_id"),
        "project_path" => receipt.fetch("project_path"),
        "worker_cwd" => worker_cwd,
        "mode" => receipt.fetch("mode"),
        "herdr_attachment" => attachment
      }
    end

    def cleanup_action(target, preserve_worktrees:)
      {
        "close_herdr_workspace" => true,
        "archive_task" => true,
        "remove_worktree" => target["mode"] == "worktree" && !preserve_worktrees,
        "preserve_branch" => true
      }
    end

    def normalize_cleanup_receipt(raw)
      raise ValidationError, "CleanupReceipt must be a mapping" unless raw.is_a?(Hash)
      return raw unless raw.key?("schemaVersion")

      expected = %w[schemaVersion taskId runtimeProjectId projectPath workerCwd mode herdrAttachment herdrWorkspaceClosed taskArchived removeWorktreeRequested worktreeRemoved branchPreserved]
      unknown = raw.keys - expected
      raise ValidationError, "CleanupReceipt has unsupported Python result fields: #{unknown.join(', ')}" unless unknown.empty?
      {
        "schema_version" => raw["schemaVersion"],
        "task_id" => raw["taskId"],
        "runtime_project_id" => raw["runtimeProjectId"],
        "project_path" => raw["projectPath"],
        "worker_cwd" => raw["workerCwd"],
        "mode" => raw["mode"],
        "herdr_attachment" => raw["herdrAttachment"],
        "herdr_workspace_closed" => raw["herdrWorkspaceClosed"],
        "task_archived" => raw["taskArchived"],
        "remove_worktree_requested" => raw["removeWorktreeRequested"],
        "worktree_removed" => raw["worktreeRemoved"],
        "branch_preserved" => raw["branchPreserved"]
      }
    end

    def validate_cleanup_plan_fields!(raw, id:, revision:, unit_id:)
      return unless raw.is_a?(Hash)

      {
        "plan_id" => id,
        "plan_revision" => revision.to_i,
        "unit_id" => unit_id
      }.each do |key, expected|
        next unless raw.key?(key)
        raise ValidationError, "CleanupReceipt #{key} does not match the requested Plan" unless raw[key] == expected
      end
    end

    def validate_cleanup_matches_target!(receipt, target)
      %w[task_id runtime_project_id mode].each do |key|
        raise ValidationError, "CleanupReceipt #{key} does not match the original DispatchReceipt" unless receipt[key] == target[key]
      end
      begin
        project_path_matches = File.realpath(receipt["project_path"]) == File.realpath(target["project_path"])
      rescue Errno::ENOENT, Errno::ELOOP, TypeError
        project_path_matches = false
      end
      raise ValidationError, "CleanupReceipt project_path does not match the original DispatchReceipt" unless project_path_matches
      unless receipt["worker_cwd"] == target["worker_cwd"]
        raise ValidationError, "CleanupReceipt worker_cwd does not match the original DispatchReceipt"
      end
      unless receipt["herdr_attachment"] == target["herdr_attachment"]
        raise ValidationError, "CleanupReceipt Herdr attachment does not match the original DispatchReceipt"
      end
    end

    def validate_cleanup_action!(receipt, action)
      unless receipt["herdr_workspace_closed"] == action["close_herdr_workspace"] &&
             receipt["task_archived"] == action["archive_task"] &&
             receipt["remove_worktree_requested"] == action["remove_worktree"] &&
             receipt["branch_preserved"] == action["preserve_branch"]
        raise ValidationError, "CleanupReceipt action does not match the requested cleanup action"
      end
    end

    def registered_non_primary_worktree?(project_path, worker_cwd)
      project = File.realpath(project_path)
      worker = File.realpath(worker_cwd)
      return false if project == worker

      output, _error, status = Open3.capture3(
        "git", "-C", project, "worktree", "list", "--porcelain"
      )
      return false unless status.success?

      output.split("\n\n").any? do |entry|
        line = entry.lines.find { |candidate| candidate.start_with?("worktree ") }
        next false unless line
        begin
          File.realpath(line.delete_prefix("worktree ").strip) == worker
        rescue Errno::ENOENT, Errno::ELOOP
          false
        end
      end
    rescue Errno::ENOENT, Errno::ELOOP, TypeError
      false
    end

    def dispatch_target(unit)
      architecture = ArchitectureMapStore.new(@config).load
      workspace = architecture.fetch("workspaces").fetch(unit["workspace"])
      logical_key = workspace.fetch("codex_project")
      expected_path = workspace.fetch("project_path")
      verification = @config.project_verification(
        logical_key: logical_key,
        expected_path: expected_path
      )
      unless verification["status"] == "verified"
        raise ValidationError,
              "dispatch target #{logical_key} is not verified by exact path: #{verification['status']}"
      end
      unless verification["runtime_project_id"] == workspace.fetch("runtime_project_id")
        raise ValidationError, "dispatch target runtime ID conflicts with the confirmed ArchitectureMap"
      end
      {
        "logical_project_key" => logical_key,
        "runtime_project_id" => verification["runtime_project_id"],
        "project_path" => File.realpath(expected_path)
      }
    end

    def revision_changes(current, candidate, retried_units = [])
      return ["Initial Plan"] unless current
      changes = []
      changes << "Objective changed" if current["objective"] != candidate["objective"]
      changes << "Constraints changed" if Array(current["constraints"]) != Array(candidate["constraints"])
      current_units = current["units"].each_with_object({}) { |unit, memo| memo[unit["id"]] = unit }
      candidate_units = candidate["units"].each_with_object({}) { |unit, memo| memo[unit["id"]] = unit }
      (candidate_units.keys - current_units.keys).sort.each { |id| changes << "Added unit #{id}" }
      (current_units.keys - candidate_units.keys).sort.each { |id| changes << "Removed unit #{id}" }
      (current_units.keys & candidate_units.keys).sort.each do |id|
        if retried_units.include?(id)
          changes << "Retried unit #{id}"
        elsif unit_spec(current_units[id]) != unit_spec(candidate_units[id])
          changes << "Changed unit #{id}"
        end
      end
      changes.empty? ? ["Metadata-only revision"] : changes
    end

    def unit_summary(unit)
      receipt = load_optional(unit["dispatch_receipt"])
      result = load_optional(unit["worker_result"])
      cleanup = load_optional(unit["cleanup_receipt"])
      {
        "id" => unit["id"],
        "state" => state(unit),
        "dependencies" => Array(unit["dependencies"]),
        "worker" => receipt && {
          "task_id" => receipt["task_id"],
          "task_url" => receipt["task_url"],
          "runtime_project_id" => receipt["runtime_project_id"],
          "project_path" => receipt["project_path"],
          "mode" => receipt["mode"],
          "requested_model" => receipt["requested_model"],
          "effective_model" => receipt["effective_model"],
          "requested_thinking" => receipt["requested_thinking"],
          "effective_thinking" => receipt["effective_thinking"],
          "herdr_attachment" => receipt["herdr_attachment"]
        }.compact,
        "context_pack" => receipt && {
          "id" => receipt["context_pack_id"],
          "estimated_tokens" => receipt["context_pack_estimated_tokens"],
          "token_budget" => receipt["context_pack_token_budget"]
        }.compact,
        "worker_result_estimated_tokens" => result && estimate_tokens(result),
        "blockers" => result ? Array(result["blockers"]) : [],
        "validation" => result ? Array(result["validation"]) : [],
        "dispatch_receipt" => unit["dispatch_receipt"],
        "worker_result" => unit["worker_result"],
        "cleanup_status" => cleanup ? "recorded" : "not_recorded",
        "cleanup_receipt" => unit["cleanup_receipt"],
        "cleanup" => cleanup && {
          "herdr_workspace_closed" => cleanup["herdr_workspace_closed"],
          "task_archived" => cleanup["task_archived"],
          "remove_worktree_requested" => cleanup["remove_worktree_requested"],
          "worktree_removed" => cleanup["worktree_removed"],
          "branch_preserved" => cleanup["branch_preserved"]
        }
      }.compact
    end

    def token_efficiency(statuses)
      {
        "measurement" => "artifact-estimates-only",
        "runtime_token_usage" => "unavailable",
        "context_pack_estimated_tokens" => statuses.sum { |item| item.dig("context_pack", "estimated_tokens").to_i },
        "context_pack_token_budget" => statuses.sum { |item| item.dig("context_pack", "token_budget").to_i },
        "worker_result_estimated_tokens" => statuses.sum { |item| item["worker_result_estimated_tokens"].to_i },
        "note" => "Portable Kepler status does not infer model token usage from ContextPack size or task state."
      }
    end

    def estimate_tokens(value)
      (JSON.generate(value).length / 4.0).ceil
    end

    def load_optional(relative_path)
      return nil unless Support.present?(relative_path)
      Support.load_data(File.join(@config.root, relative_path))
    end

    def current_id
      path = File.join(@config.plan_dir, "current")
      raise ValidationError, "no current Plan" unless File.file?(path)
      File.read(path, encoding: "UTF-8").strip
    end

    def plan_path(id)
      File.join(@config.plan_dir, "#{id}.yaml")
    end

    def ready_units(plan)
      completed = plan["units"].select { |unit| state(unit) == "completed" }.map { |unit| unit["id"] }
      plan["units"].select do |unit|
        state(unit) == "ready" && (Array(unit["dependencies"]) - completed).empty?
      end
    end

    def normalize_readiness!(plan)
      completed = plan["units"].select { |unit| state(unit) == "completed" }.map { |unit| unit["id"] }
      plan["units"].each do |unit|
        next unless %w[planned ready waiting].include?(state(unit))
        next_state = (Array(unit["dependencies"]) - completed).empty? ? "ready" : "waiting"
        unit["status"] = { "state" => next_state }
      end
      states = plan["units"].map { |unit| state(unit) }
      plan_state = if states.all? { |value| value == "completed" }
                     "completed"
                   elsif states.any? { |value| value == "failed" }
                     "failed"
                   elsif states.any? { |value| value == "blocked" }
                     "blocked"
                   elsif states.any? { |value| value == "working" }
                     "working"
                   elsif states.any? { |value| value == "dispatched" }
                     "dispatched"
                   elsif states.any? { |value| value == "ready" }
                     "ready"
                   elsif states.all? { |value| value == "cancelled" }
                     "cancelled"
                   else
                     "draft"
                   end
      plan["status"] = { "state" => plan_state }
    end

    def state(unit)
      status = unit["status"]
      status.is_a?(Hash) ? status["state"] : (status || "planned")
    end

    def find_unit(plan, unit_id)
      plan["units"].find { |unit| unit["id"] == unit_id } || raise(ValidationError, "unknown Plan unit: #{unit_id}")
    end

    def assert_revision!(plan, revision)
      actual = plan.dig("metadata", "revision").to_i
      raise ValidationError, "stale Plan revision: requested #{revision}, current #{actual}" unless actual == revision.to_i
    end

    def update(id, revision)
      with_lock(id) do
        plan = load(id)
        assert_revision!(plan, revision)
        yield(plan)
        plan["metadata"]["updated_at"] = Time.now.utc.iso8601
        Support.atomic_yaml(plan_path(id), plan)
        summary(plan)
      end
    end

    def with_lock(id)
      FileUtils.mkdir_p(@config.plan_dir)
      File.open(File.join(@config.plan_dir, ".#{id}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end

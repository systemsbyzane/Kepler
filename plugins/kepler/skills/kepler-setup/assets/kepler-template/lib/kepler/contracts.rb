# frozen_string_literal: true

require_relative "support"

module Kepler
  module Contracts
    module_function

    API_VERSION = "kepler.dev/v1"
    PLAN_STATES = %w[draft ready dispatched working blocked completed failed cancelled].freeze
    UNIT_STATES = %w[planned ready waiting dispatched working blocked completed failed cancelled].freeze
    MEMORY_SCOPES = %w[SYSTEM WORKSPACE DOMAIN WORK].freeze
    MEMORY_TYPES = %w[FACT DECISION CONSTRAINT ATTEMPT RELATIONSHIP ARTIFACT SUMMARY].freeze

    def architecture_map!(value)
      document!(value, "ArchitectureMap")
      metadata = mapping!(value["metadata"], "ArchitectureMap metadata")
      raise ValidationError, "ArchitectureMap requires explicit confirmation" unless metadata["confirmed"] == true
      workspaces = value["workspaces"]
      raise ValidationError, "ArchitectureMap workspaces must be a non-empty mapping" unless workspaces.is_a?(Hash) && !workspaces.empty?

      qualified_domains = []
      workspaces.each do |workspace_id, workspace|
        Support.validate_identifier!(workspace_id, label: "workspace id")
        raise ValidationError, "workspace #{workspace_id} must be a mapping" unless workspace.is_a?(Hash)
        %w[codex_project project_path runtime_project_id domains].each do |key|
          raise ValidationError, "workspace #{workspace_id} is missing #{key}" unless Support.present?(workspace[key])
        end
        raise ValidationError, "workspace #{workspace_id} project_path must be absolute" unless Pathname.new(workspace["project_path"].to_s).absolute?
        raise ValidationError, "workspace #{workspace_id} domains must be a mapping" unless workspace["domains"].is_a?(Hash)
        workspace["domains"].each do |domain_id, domain|
          Support.validate_identifier!(domain_id, label: "domain id")
          paths = domain.is_a?(Hash) ? domain["paths"] : nil
          raise ValidationError, "domain #{workspace_id}.#{domain_id} paths must be a non-empty array" unless paths.is_a?(Array) && !paths.empty?
          paths.each { |path| relative_path!(path, "domain path") }
          qualified_domains << "#{workspace_id}.#{domain_id}"
        end
      end
      relationships = value.fetch("relationships", {})
      raise ValidationError, "ArchitectureMap relationships must be a mapping" unless relationships.is_a?(Hash)
      relationships.each do |source, declarations|
        raise ValidationError, "relationship source is unknown: #{source}" unless qualified_domains.include?(source)
        raise ValidationError, "relationships for #{source} must be a mapping" unless declarations.is_a?(Hash)
        declarations.each do |relationship, targets|
          Support.validate_identifier!(relationship, label: "relationship type")
          raise ValidationError, "relationship #{source}.#{relationship} must be a non-empty array" unless targets.is_a?(Array) && !targets.empty?
          targets.each do |target|
            raise ValidationError, "relationship target is unknown: #{target}" unless qualified_domains.include?(target)
            raise ValidationError, "relationship cannot reference itself: #{source}" if target == source
          end
        end
      end
      value
    end

    def plan!(value)
      document!(value, "Plan")
      metadata = mapping!(value["metadata"], "Plan metadata")
      Support.validate_identifier!(metadata["id"], label: "Plan id")
      revision = Integer(metadata["revision"])
      raise ValidationError, "Plan revision must be positive" unless revision.positive?
      objective = value["objective"]
      objective = objective["summary"] if objective.is_a?(Hash)
      raise ValidationError, "Plan objective is required" unless Support.present?(objective)
      units = value["units"]
      raise ValidationError, "Plan units must be a non-empty array" unless units.is_a?(Array) && !units.empty?
      ids = {}
      units.each do |unit|
        mapping!(unit, "Plan unit")
        id = Support.validate_identifier!(unit["id"], label: "unit id")
        raise ValidationError, "duplicate Plan unit: #{id}" if ids[id]
        ids[id] = true
        %w[workspace domain].each { |key| raise ValidationError, "unit #{id} is missing #{key}" unless Support.present?(unit[key]) }
        Array(unit["paths"]).each { |path| relative_path!(path, "unit path") }
        status = unit["status"]
        state = status.is_a?(Hash) ? status["state"] : (status || "planned")
        raise ValidationError, "unit #{id} has unsupported state #{state}" unless UNIT_STATES.include?(state)
      end
      units.each do |unit|
        Array(unit["dependencies"]).each do |dependency|
          raise ValidationError, "unit #{unit['id']} has unknown dependency #{dependency}" unless ids[dependency]
          raise ValidationError, "unit #{unit['id']} depends on itself" if dependency == unit["id"]
        end
      end
      detect_cycle!(units)
      state = value.dig("status", "state") || "draft"
      raise ValidationError, "Plan has unsupported state #{state}" unless PLAN_STATES.include?(state)
      value
    rescue ArgumentError, TypeError
      raise ValidationError, "Plan revision must be an integer"
    end

    def context_pack!(value)
      document!(value, "ContextPack")
      metadata = mapping!(value["metadata"], "ContextPack metadata")
      Support.validate_identifier!(metadata["id"], label: "ContextPack id")
      parent = mapping!(value["parent_plan"], "ContextPack parent_plan")
      Support.validate_identifier!(parent["id"], label: "parent Plan id")
      raise ValidationError, "ContextPack objective is required" unless Support.present?(value["objective"])
      policy = mapping!(value["worker_policy"], "ContextPack worker_policy")
      raise ValidationError, "ContextPack must preserve worker capability" unless policy["initial_context_not_boundary"] == true
      raise ValidationError, "ContextPack must request a WorkerResult" unless policy["return_worker_result"] == true
      raise ValidationError, "ContextPack must request a structured-only WorkerResult" unless policy["structured_result_only"] == true
      raise ValidationError, "ContextPack must prohibit repeated context" unless policy["avoid_context_repetition"] == true
      begin
        result_budget = Integer(policy["result_token_budget"])
      rescue ArgumentError, TypeError
        raise ValidationError, "ContextPack result token budget must be an integer"
      end
      raise ValidationError, "ContextPack result token budget must be positive" unless result_budget.positive?
      value
    end

    def worker_result!(value)
      document!(value, "WorkerResult")
      metadata = mapping!(value["metadata"], "WorkerResult metadata")
      %w[id plan_id plan_revision unit_id].each do |key|
        raise ValidationError, "WorkerResult metadata is missing #{key}" unless Support.present?(metadata[key])
      end
      raise ValidationError, "WorkerResult status is unsupported" unless %w[completed blocked failed].include?(value["status"])
      raise ValidationError, "WorkerResult summary is required" unless Support.present?(value["summary"])
      validation = value["validation"]
      raise ValidationError, "WorkerResult validation must be an array" unless validation.is_a?(Array)
      %w[changes discoveries decisions failed_attempts inferences blockers artifacts memory_candidates].each do |key|
        next unless value.key?(key)
        raise ValidationError, "WorkerResult #{key} must be an array" unless value[key].is_a?(Array)
      end
      if value.key?("handoffs") && !value["handoffs"].is_a?(Hash) && !value["handoffs"].is_a?(Array)
        raise ValidationError, "WorkerResult handoffs must be a mapping or array"
      end
      value
    end

    def dispatch_receipt!(value)
      document!(value, "DispatchReceipt")
      %w[task_id runtime_project_id project_path mode requested_model effective_model requested_thinking effective_thinking authorization_boundary creation_method bootstrap_schema_version bootstrap_task_id bootstrap_expected_runtime_project_id bootstrap_actual_runtime_project_id configuration_verification_schema_version configuration_verified configuration_verified_task_id configuration_verified_before_prompt configuration_verified_runtime_project_id post_delivery_project_verification_schema_version post_delivery_project_verified post_delivery_project_verified_task_id post_delivery_verified_runtime_project_id configuration_mode approval_policy context_pack_id context_pack_estimated_tokens context_pack_token_budget dispatch_execution dispatch_owner_task_id dispatch_owner_project_path prompt_delivery_method project_association_verification_source project_association_before project_association_after].each do |key|
        raise ValidationError, "DispatchReceipt is missing #{key}" unless Support.present?(value[key])
      end
      %w[permission_profile sandbox_mode intermediary_dispatch_task_created post_delivery_verified_empty].each do |key|
        raise ValidationError, "DispatchReceipt is missing #{key}" unless value.key?(key)
      end
      unless (value["approval_policy"].is_a?(String) || value["approval_policy"].is_a?(Hash)) && Support.present?(value["approval_policy"])
        raise ValidationError, "DispatchReceipt approval policy is invalid"
      end
      unless value["requested_model"] == value["effective_model"]
        raise ValidationError, "DispatchReceipt effective model does not match requested model"
      end
      unless value["requested_thinking"] == value["effective_thinking"]
        raise ValidationError, "DispatchReceipt effective thinking does not match requested thinking"
      end
      unless value["creation_method"] == "kepler-bootstrap-worker-task"
        raise ValidationError, "DispatchReceipt must use the Kepler worker bootstrap"
      end
      unless value["bootstrap_schema_version"] == "kepler.worker-task-bootstrap/v1"
        raise ValidationError, "DispatchReceipt bootstrap evidence is unsupported"
      end
      unless value["configuration_verification_schema_version"] == "kepler.worker-task-verification/v1"
        raise ValidationError, "DispatchReceipt configuration verification evidence is unsupported"
      end
      unless %w[kepler.worker-task-verification/v1 kepler.herdr-prompt-delivery/v1].include?(value["post_delivery_project_verification_schema_version"])
        raise ValidationError, "DispatchReceipt post-delivery project verification evidence is unsupported"
      end
      unless value["configuration_verified"] == true && value["configuration_verified_before_prompt"] == true
        raise ValidationError, "DispatchReceipt configuration must be verified before the worker prompt"
      end
      unless value["post_delivery_project_verified"] == true
        raise ValidationError, "DispatchReceipt project association must be verified after prompt delivery"
      end
      unless value["post_delivery_verified_empty"] == false
        raise ValidationError, "DispatchReceipt post-delivery task must contain the delivered prompt"
      end
      unless value["configuration_verified_task_id"] == value["task_id"]
        raise ValidationError, "DispatchReceipt verification task does not match the final worker task"
      end
      unless value["post_delivery_project_verified_task_id"] == value["task_id"]
        raise ValidationError, "DispatchReceipt post-delivery verification task does not match the final worker task"
      end
      %w[bootstrap_expected_runtime_project_id bootstrap_actual_runtime_project_id configuration_verified_runtime_project_id post_delivery_verified_runtime_project_id].each do |key|
        unless value[key] == value["runtime_project_id"]
          raise ValidationError, "DispatchReceipt app-server project identity does not match the owning runtime project"
        end
      end
      unless value["dispatch_execution"] == "current-control-task" &&
             value["intermediary_dispatch_task_created"] == false
        raise ValidationError, "DispatchReceipt must be executed by the current control task without an intermediary dispatcher"
      end
      if value["dispatch_owner_task_id"] == value["task_id"]
        raise ValidationError, "DispatchReceipt control task cannot also be the repository worker"
      end
      case value["prompt_delivery_method"]
      when "codex-thread-message"
        unless value["post_delivery_project_verification_schema_version"] == "kepler.worker-task-verification/v1" &&
               value["project_association_verification_source"] == "live-project-and-task-list"
          raise ValidationError, "DispatchReceipt Codex messaging requires live project and task verification"
        end
      when "herdr-agent-prompt"
        unless value["post_delivery_project_verification_schema_version"] == "kepler.herdr-prompt-delivery/v1" &&
               value["project_association_verification_source"] == "cli-app-server-and-herdr-terminal"
          raise ValidationError, "DispatchReceipt Herdr delivery requires CLI task and terminal verification"
        end
        prompt_bytes = begin
          Integer(value["prompt_bytes"])
        rescue ArgumentError, TypeError
          nil
        end
        unless value["prompt_delivery_schema_version"] == "kepler.herdr-prompt-delivery/v1" &&
               Support.present?(value["prompt_delivery_id"]) &&
               value["prompt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               prompt_bytes&.positive? && value.key?("herdr_attachment")
          raise ValidationError, "DispatchReceipt Herdr prompt evidence is incomplete"
        end
        attachment = value["herdr_attachment"]
        unless attachment.is_a?(Hash) &&
               attachment["attachment_mode"] == "shared-control-workspace" &&
               attachment["workspace_owned"] == false &&
               Support.present?(attachment["control_tab_id"]) &&
               Support.present?(attachment["control_pane_id"]) &&
               Support.present?(attachment["terminal_id"]) &&
               attachment["resume_argv_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise ValidationError, "DispatchReceipt Herdr launch identity evidence is incomplete"
        end
      else
        raise ValidationError, "DispatchReceipt prompt delivery method is unsupported"
      end
      before = mapping!(value["project_association_before"], "DispatchReceipt project association before prompt")
      after = mapping!(value["project_association_after"], "DispatchReceipt project association after prompt")
      [before, after].each do |association|
        unless association["runtime_project_id"] == value["runtime_project_id"] &&
               association["project_path"] == value["project_path"] &&
               Support.present?(association["task_cwd"])
          raise ValidationError, "DispatchReceipt worker project association drifted from the verified target"
        end
      end
      unless before["task_cwd"] == after["task_cwd"]
        raise ValidationError, "DispatchReceipt worker task path changed during prompt delivery"
      end
      herdr_attachment!(value["herdr_attachment"], task_id: value["task_id"], worker_cwd: before["task_cwd"]) if value.key?("herdr_attachment")
      begin
        estimated = Integer(value["context_pack_estimated_tokens"])
        budget = Integer(value["context_pack_token_budget"])
      rescue ArgumentError, TypeError
        raise ValidationError, "DispatchReceipt ContextPack token accounting must use integers"
      end
      unless estimated.positive? && budget.positive? && estimated <= budget
        raise ValidationError, "DispatchReceipt ContextPack token accounting is invalid"
      end
      case value["configuration_mode"]
      when "global-config"
        raise ValidationError, "DispatchReceipt global config requires sandbox_mode" unless Support.present?(value["sandbox_mode"])
        raise ValidationError, "DispatchReceipt global config cannot select permission_profile" if Support.present?(value["permission_profile"])
      when "permission-profile"
        raise ValidationError, "DispatchReceipt permission profile is required" unless Support.present?(value["permission_profile"])
        raise ValidationError, "DispatchReceipt permission profile cannot select sandbox_mode" if Support.present?(value["sandbox_mode"])
      else
        raise ValidationError, "DispatchReceipt configuration mode is unsupported"
      end
      value
    end

    def cleanup_receipt!(value)
      document!(value, "CleanupReceipt")
      required = %w[api_version kind schema_version plan_id plan_revision unit_id task_id runtime_project_id project_path worker_cwd mode herdr_attachment task_archived remove_worktree_requested worktree_removed branch_preserved]
      lifecycle_fields = %w[herdr_workspace_closed herdr_workspace_preserved herdr_worker_tab_closed]
      unknown = value.keys - required - lifecycle_fields
      raise ValidationError, "CleanupReceipt has unsupported fields: #{unknown.join(', ')}" unless unknown.empty?
      %w[schema_version plan_id plan_revision unit_id task_id runtime_project_id project_path worker_cwd mode herdr_attachment].each do |key|
        raise ValidationError, "CleanupReceipt is missing #{key}" unless Support.present?(value[key])
      end
      %w[task_archived remove_worktree_requested worktree_removed branch_preserved].each do |key|
        raise ValidationError, "CleanupReceipt is missing #{key}" unless value.key?(key)
      end
      unless %w[kepler.worker-cleanup/v1 kepler.worker-cleanup/v2].include?(value["schema_version"])
        raise ValidationError, "CleanupReceipt schema version is unsupported"
      end
      begin
        revision = Integer(value["plan_revision"])
      rescue ArgumentError, TypeError
        raise ValidationError, "CleanupReceipt plan revision must be an integer"
      end
      raise ValidationError, "CleanupReceipt plan revision must be positive" unless revision.positive?
      herdr_attachment!(value["herdr_attachment"], task_id: value["task_id"], worker_cwd: value["worker_cwd"])
      case value["schema_version"]
      when "kepler.worker-cleanup/v1"
        unless value["herdr_workspace_closed"] == true
          raise ValidationError, "CleanupReceipt must close the legacy owned Herdr workspace"
        end
      when "kepler.worker-cleanup/v2"
        unless value["herdr_workspace_preserved"] == true && value["herdr_worker_tab_closed"] == true
          raise ValidationError, "CleanupReceipt must preserve the control workspace and close the worker tab"
        end
      end
      unless value["task_archived"] == true && value["branch_preserved"] == true
        raise ValidationError, "CleanupReceipt must archive the task and preserve the branch"
      end
      unless [true, false].include?(value["remove_worktree_requested"]) && [true, false].include?(value["worktree_removed"])
        raise ValidationError, "CleanupReceipt worktree outcomes must be boolean"
      end
      unless value["worktree_removed"] == value["remove_worktree_requested"]
        raise ValidationError, "CleanupReceipt worktree removal outcome does not match the requested action"
      end
      value
    end

    def memory_item!(value)
      document!(value, "MemoryItem")
      metadata = mapping!(value["metadata"], "MemoryItem metadata")
      Support.validate_identifier!(metadata["id"], label: "memory id")
      raise ValidationError, "unsupported memory scope" unless MEMORY_SCOPES.include?(value["scope"])
      raise ValidationError, "unsupported memory type" unless MEMORY_TYPES.include?(value["type"])
      raise ValidationError, "memory statement is required" unless Support.present?(value["statement"])
      raise ValidationError, "memory source is required" unless Support.present?(value["source"])
      case value["scope"]
      when "WORKSPACE"
        raise ValidationError, "WORKSPACE memory requires workspace" unless Support.present?(value["workspace"])
      when "DOMAIN", "WORK"
        raise ValidationError, "#{value['scope']} memory requires workspace" unless Support.present?(value["workspace"])
        raise ValidationError, "#{value['scope']} memory requires domain" unless Support.present?(value["domain"])
      end
      Array(value["supersedes"]).each { |id| Support.validate_identifier!(id, label: "superseded memory id") }
      confidence = value.fetch("confidence", 0.5).to_f
      raise ValidationError, "memory confidence must be between 0 and 1" unless confidence.between?(0.0, 1.0)
      value
    end

    def document!(value, kind)
      mapping!(value, kind)
      raise ValidationError, "#{kind} must use #{API_VERSION}" unless value["api_version"] == API_VERSION
      raise ValidationError, "expected #{kind}, got #{value['kind'].inspect}" unless value["kind"] == kind
    end

    def mapping!(value, label)
      raise ValidationError, "#{label} must be a mapping" unless value.is_a?(Hash)
      value
    end

    def herdr_attachment!(value, task_id:, worker_cwd:)
      attachment = mapping!(value, "Herdr attachment")
      required = %w[schema_version herdr_version protocol workspace_id tab_id pane_id agent_name agent_kind resumed_task_id worker_cwd workspace_owned tab_owned pane_owned agent_owned]
      runtime_fields = %w[model thinking configuration_mode permission_profile sandbox_mode approval_policy]
      launch_fields = %w[terminal_id resume_argv_sha256]
      shared_fields = %w[attachment_mode control_tab_id control_pane_id]
      unknown = attachment.keys - required - runtime_fields - launch_fields - shared_fields
      raise ValidationError, "Herdr attachment has unsupported fields: #{unknown.join(', ')}" unless unknown.empty?
      %w[schema_version herdr_version protocol workspace_id tab_id pane_id agent_name agent_kind resumed_task_id worker_cwd].each do |key|
        raise ValidationError, "Herdr attachment is missing #{key}" unless Support.present?(attachment[key])
      end
      %w[workspace_owned tab_owned pane_owned agent_owned].each do |key|
        raise ValidationError, "Herdr attachment is missing #{key}" unless attachment.key?(key)
      end
      unless attachment["schema_version"] == "kepler.herdr-attachment/v1" && attachment["agent_kind"] == "codex"
        raise ValidationError, "Herdr attachment is unsupported"
      end
      begin
        protocol = Integer(attachment["protocol"])
      rescue ArgumentError, TypeError
        raise ValidationError, "Herdr attachment protocol must be an integer"
      end
      raise ValidationError, "Herdr attachment protocol must be at least 19" unless protocol >= 19
      unless attachment["resumed_task_id"] == task_id
        raise ValidationError, "Herdr attachment resumed task does not match the worker task"
      end
      unless attachment["worker_cwd"] == worker_cwd
        raise ValidationError, "Herdr attachment worker path does not match the worker task"
      end
      unless attachment["tab_owned"] == true && attachment["pane_owned"] == true && attachment["agent_owned"] == true
        raise ValidationError, "Herdr attachment must own its tab, pane, and agent"
      end
      case attachment["attachment_mode"]
      when "shared-control-workspace"
        unless attachment["workspace_owned"] == false && Support.present?(attachment["control_tab_id"]) && Support.present?(attachment["control_pane_id"])
          raise ValidationError, "shared Herdr attachment must preserve and identify the control workspace"
        end
        if attachment["tab_id"] == attachment["control_tab_id"] || attachment["pane_id"] == attachment["control_pane_id"]
          raise ValidationError, "Herdr worker attachment cannot reuse the control tab or pane"
        end
      when nil
        unless attachment["workspace_owned"] == true
          raise ValidationError, "legacy Herdr attachment must own its worker workspace"
        end
      else
        raise ValidationError, "Herdr attachment mode is unsupported"
      end
      if (attachment.keys & launch_fields).any?
        missing = launch_fields - attachment.keys
        raise ValidationError, "Herdr attachment launch evidence is incomplete: #{missing.join(', ')}" unless missing.empty?
        raise ValidationError, "Herdr attachment terminal is missing" unless Support.present?(attachment["terminal_id"])
        unless attachment["resume_argv_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise ValidationError, "Herdr attachment resume argv digest is invalid"
        end
      end
      if (attachment.keys & runtime_fields).any?
        missing = runtime_fields - attachment.keys
        raise ValidationError, "Herdr attachment runtime evidence is incomplete: #{missing.join(', ')}" unless missing.empty?
        raise ValidationError, "Herdr attachment model is missing" unless Support.present?(attachment["model"])
        raise ValidationError, "Herdr attachment thinking is missing" unless Support.present?(attachment["thinking"])
        unless %w[global-config permission-profile].include?(attachment["configuration_mode"])
          raise ValidationError, "Herdr attachment configuration mode is unsupported"
        end
      end
      attachment
    end

    def relative_path!(value, label)
      path = value.to_s
      raise ValidationError, "#{label} must be relative: #{value}" if path.empty? || Pathname.new(path).absolute? || path.split(/[\\\/]/).include?("..")
      path
    end

    def detect_cycle!(units)
      dependencies = units.each_with_object({}) { |unit, memo| memo[unit["id"]] = Array(unit["dependencies"]) }
      visiting = {}
      visited = {}
      visit = lambda do |id|
        raise ValidationError, "Plan dependency cycle includes #{id}" if visiting[id]
        return if visited[id]
        visiting[id] = true
        dependencies.fetch(id).each { |dependency| visit.call(dependency) }
        visiting.delete(id)
        visited[id] = true
      end
      dependencies.keys.each { |id| visit.call(id) }
    end
  end
end

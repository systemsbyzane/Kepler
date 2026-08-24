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
      %w[task_id runtime_project_id project_path mode requested_model effective_model requested_thinking effective_thinking authorization_boundary].each do |key|
        raise ValidationError, "DispatchReceipt is missing #{key}" unless Support.present?(value[key])
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

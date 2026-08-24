# frozen_string_literal: true

require "fileutils"
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
      {
        "plan_id" => plan.dig("metadata", "id"),
        "revision" => plan.dig("metadata", "revision"),
        "change_summary" => Array(plan.dig("metadata", "change_summary")),
        "state" => plan.dig("status", "state"),
        "units" => states,
        "unit_status" => plan["units"].map { |unit| unit_summary(unit) },
        "ready_units" => ready_units(plan).map { |unit| unit["id"] }
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
        destination = File.join(@config.dispatch_receipt_dir, "#{id}-r#{revision}-#{unit_id}.yaml")
        Support.atomic_yaml(destination, receipt.merge("plan_id" => id, "plan_revision" => revision.to_i, "unit_id" => unit_id))
        unit["status"] = { "state" => "dispatched", "updated_at" => Time.now.utc.iso8601 }
        unit["dispatch_receipt"] = Support.relative_path(@config.root, destination)
        plan["status"] = { "state" => "dispatched" }
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
        summary(plan)
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
          unit["status"] = { "state" => "planned" }
          retried_units << unit["id"]
          next
        end

        unless unit_spec(previous) == unit_spec(unit)
          raise ValidationError,
                "Plan revision cannot change execution-bound unit #{unit['id']} without an explicit blocked/failed retry"
        end
        %w[status dispatch_receipt worker_result].each do |key|
          unit[key] = previous[key] if previous.key?(key)
        end
      end
      retried_units
    end

    def unit_spec(unit)
      unit.reject do |key, _value|
        %w[status dispatch_receipt worker_result retry].include?(key)
      end
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
          "effective_thinking" => receipt["effective_thinking"]
        }.compact,
        "blockers" => result ? Array(result["blockers"]) : [],
        "validation" => result ? Array(result["validation"]) : [],
        "dispatch_receipt" => unit["dispatch_receipt"],
        "worker_result" => unit["worker_result"]
      }.compact
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

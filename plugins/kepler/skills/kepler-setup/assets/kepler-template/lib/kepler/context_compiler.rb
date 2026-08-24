# frozen_string_literal: true

require_relative "architecture_map_store"
require_relative "contracts"
require_relative "memory_store"

module Kepler
  class ContextCompiler
    DEFAULT_BUDGET = 2_000

    def initialize(config)
      @config = config
    end

    def compile(plan:, unit:, budget: DEFAULT_BUDGET)
      workspace = unit.fetch("workspace")
      domain = unit.fetch("domain")
      architecture = ArchitectureMapStore.new(@config).load
      workspace_entry = architecture.fetch("workspaces").fetch(workspace) do
        raise ValidationError, "Plan unit #{unit['id']} references unknown workspace #{workspace}"
      end
      domain_entry = workspace_entry.fetch("domains").fetch(domain) do
        raise ValidationError, "Plan unit #{unit['id']} references unknown domain #{workspace}.#{domain}"
      end
      objective = plan["objective"].is_a?(Hash) ? plan["objective"]["summary"] : plan["objective"]
      memory_budget = [budget.to_i / 3, 600].min
      memory = MemoryStore.new(@config).query(
        text: objective,
        workspace: workspace,
        domain: "#{workspace}.#{domain}",
        limit: 6,
        token_budget: memory_budget
      )
      handoffs = upstream_handoffs(plan, unit)
      revision = plan.dig("metadata", "revision")
      plan_id = plan.dig("metadata", "id")
      id = "ctx-#{plan_id}-#{unit['id']}-r#{revision}"
      pack = {
        "api_version" => Contracts::API_VERSION,
        "kind" => "ContextPack",
        "metadata" => { "id" => id, "compiled_at" => Time.now.utc.iso8601 },
        "parent_plan" => { "id" => plan.dig("metadata", "id"), "revision" => revision },
        "role" => unit["role"] || "#{domain} Codex worker",
        "objective" => unit["objective"] || objective,
        "scope" => {
          "workspace" => workspace,
          "codex_project" => workspace_entry["codex_project"],
          "runtime_project_id" => workspace_entry["runtime_project_id"],
          "project_path" => workspace_entry["project_path"],
          "domain" => domain,
          "paths" => Array(unit["paths"])
        },
        "architecture" => deduplicate(Array(domain_entry["facts"])),
        "relevant_facts" => memory["items"].map { |item| { "statement" => item["statement"], "memory_id" => item.dig("metadata", "id"), "included_because" => item.dig("retrieval", "reason") } },
        "prior_attempts" => memory["items"].select { |item| item["type"] == "ATTEMPT" }.map { |item| item["statement"] },
        "dependencies" => deduplicate(Array(unit["dependencies"])),
        "upstream_handoffs" => handoffs,
        "related_work" => plan["units"].reject { |candidate| candidate["id"] == unit["id"] }.map { |candidate| { "unit" => candidate["id"], "status" => state(candidate) } },
        "references" => deduplicate(Array(unit["references"])),
        "constraints" => deduplicate(Array(plan["constraints"]) + Array(unit["constraints"])),
        "success_criteria" => deduplicate(Array(unit["success_criteria"])),
        "telemetry" => {
          "memory" => memory["telemetry"],
          "upstream_handoff_count" => handoffs.length
        },
        "worker_policy" => {
          "initial_context_not_boundary" => true,
          "return_worker_result" => true,
          "instruction" => "These references and paths are initial relevant context, not an exclusive boundary. Follow repository evidence wherever necessary to complete the task correctly."
        }
      }
      estimated = estimate_tokens(pack)
      pack["metadata"]["estimated_tokens"] = estimated
      pack["metadata"]["token_budget"] = budget.to_i
      raise ValidationError, "ContextPack #{id} exceeds token budget: #{estimated} > #{budget}" if estimated > budget.to_i
      Contracts.context_pack!(pack)
      path = File.join(@config.context_pack_dir, "#{id}.yaml")
      Support.atomic_yaml(path, pack)
      [pack, path]
    end

    private

    def upstream_handoffs(plan, unit)
      Array(unit["dependencies"]).each_with_object([]) do |dependency_id, output|
        dependency = plan["units"].find { |candidate| candidate["id"] == dependency_id }
        next unless dependency && Support.present?(dependency["worker_result"])
        result = Contracts.worker_result!(
          Support.load_data(File.join(@config.root, dependency["worker_result"]))
        )
        handoffs = result["handoffs"]
        selected = if handoffs.is_a?(Hash)
                     Array(handoffs[unit["id"]]) + Array(handoffs["all"])
                   else
                     Array(handoffs)
                   end
        next if selected.empty?
        output << {
          "upstream_unit" => dependency_id,
          "worker_result" => dependency["worker_result"],
          "items" => deduplicate(selected)
        }
      end
    end

    def deduplicate(values)
      seen = {}
      values.each_with_object([]) do |value, output|
        key = JSON.generate(value)
        next if seen[key]
        seen[key] = true
        output << value
      end
    end

    def state(unit)
      status = unit["status"]
      status.is_a?(Hash) ? status["state"] : (status || "planned")
    end

    def estimate_tokens(value)
      (JSON.generate(value).length / 4.0).ceil
    end
  end
end

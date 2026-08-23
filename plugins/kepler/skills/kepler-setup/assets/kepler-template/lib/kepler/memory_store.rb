# frozen_string_literal: true

require_relative "contracts"

module Kepler
  class MemoryStore
    def initialize(config)
      @config = config
    end

    def ingest(source_path)
      item = Contracts.memory_item!(Support.load_data(source_path))
      path = item_path(item.dig("metadata", "id"))
      existing = File.file?(path) ? Contracts.memory_item!(Support.load_data(path)) : nil
      if existing && existing["statement"] != item["statement"] && !Support.present?(item["supersedes"])
        raise ValidationError, "memory #{item.dig('metadata', 'id')} conflicts with an existing item; provide supersedes"
      end
      duplicate = active_items.find do |candidate|
        candidate.dig("metadata", "id") != item.dig("metadata", "id") &&
          identity(candidate) == identity(item)
      end
      if duplicate
        return {
          "status" => "duplicate",
          "id" => duplicate.dig("metadata", "id"),
          "path" => Support.relative_path(@config.root, item_path(duplicate.dig("metadata", "id")))
        }
      end
      superseded = Array(item["supersedes"])
      superseded.each do |identifier|
        target_path = item_path(identifier)
        raise ValidationError, "superseded memory does not exist: #{identifier}" unless File.file?(target_path)
        target = Contracts.memory_item!(Support.load_data(target_path))
        target["invalidated"] = true
        target["superseded_by"] = item.dig("metadata", "id")
        target["metadata"]["updated_at"] = Time.now.utc.iso8601
        Support.atomic_yaml(target_path, target)
      end
      item["metadata"]["created_at"] ||= existing&.dig("metadata", "created_at") || Time.now.utc.iso8601
      item["metadata"]["updated_at"] = Time.now.utc.iso8601
      Support.atomic_yaml(path, item)
      {
        "status" => existing ? "updated" : "stored",
        "id" => item.dig("metadata", "id"),
        "path" => Support.relative_path(@config.root, path),
        "superseded" => superseded
      }
    end

    def query(text:, workspace: nil, domain: nil, limit: 8, include_work: false, token_budget: 600)
      tokens = text.to_s.downcase.scan(/[a-z0-9_-]+/).uniq
      now = Time.now.utc
      rejected = { "invalidated" => 0, "expired" => 0, "scope" => 0, "budget" => 0 }
      items = Dir.glob(File.join(@config.memory_dir, "*.yaml")).each_with_object([]) do |path, matches|
        item = Contracts.memory_item!(Support.load_data(path))
        if item["invalidated"] == true
          rejected["invalidated"] += 1
          next
        end
        expires_at = parse_time(item["expires_at"])
        if expires_at && expires_at <= now
          rejected["expired"] += 1
          next
        end
        if (item["scope"] == "WORK" && !include_work) ||
           (workspace && item["workspace"] && item["workspace"] != workspace) ||
           (domain && item["domain"] && item["domain"] != domain)
          rejected["scope"] += 1
          next
        end
        corpus = [item["statement"], item["workspace"], item["domain"], item["type"]].compact.join(" ").downcase
        lexical = tokens.count { |token| corpus.include?(token) }
        scope = item["domain"] == domain ? 8 : (item["workspace"] == workspace ? 5 : 1)
        importance = item.fetch("importance", 0).to_i
        confidence = (item.fetch("confidence", 0.5).to_f * 4).round
        attempt = item["type"] == "ATTEMPT" ? 3 : 0
        updated = parse_time(item.dig("metadata", "updated_at") || item.dig("metadata", "created_at")) || Time.at(0).utc
        recency = updated > now - (90 * 86_400) ? 2 : (updated < now - (365 * 86_400) ? -3 : 0)
        matches << [scope + lexical * 3 + importance + confidence + attempt + recency, item]
      end
      used_tokens = 0
      ranked = []
      items.sort_by { |score, item| [-score, item.dig("metadata", "id")] }.each do |score, item|
        break if ranked.length >= limit.to_i
        estimate = (JSON.generate(item).length / 4.0).ceil
        if used_tokens + estimate > token_budget.to_i
          rejected["budget"] += 1
          next
        end
        used_tokens += estimate
        ranked << item.merge(
          "retrieval" => {
            "score" => score,
            "reason" => retrieval_reason(item, workspace, domain),
            "estimated_tokens" => estimate
          }
        )
      end
      {
        "query" => text,
        "items" => ranked,
        "count" => ranked.length,
        "telemetry" => {
          "candidates" => items.length,
          "selected" => ranked.length,
          "estimated_tokens" => used_tokens,
          "token_budget" => token_budget.to_i,
          "rejected" => rejected
        }
      }
    end

    private

    def item_path(id)
      Support.validate_identifier!(id, label: "memory id")
      File.join(@config.memory_dir, "#{id}.yaml")
    end

    def active_items
      Dir.glob(File.join(@config.memory_dir, "*.yaml")).map do |path|
        Contracts.memory_item!(Support.load_data(path))
      end.reject { |item| item["invalidated"] == true }
    end

    def identity(item)
      [item["scope"], item["workspace"], item["domain"], item["type"], item["statement"].strip.downcase]
    end

    def parse_time(value)
      return nil unless Support.present?(value)
      Time.parse(value.to_s)
    rescue ArgumentError
      raise ValidationError, "memory timestamp is invalid: #{value}"
    end

    def retrieval_reason(item, workspace, domain)
      return "domain match and task relevance" if domain && item["domain"] == domain
      return "workspace match and task relevance" if workspace && item["workspace"] == workspace
      item["type"] == "ATTEMPT" ? "applicable prior attempt" : "objective relevance"
    end
  end
end

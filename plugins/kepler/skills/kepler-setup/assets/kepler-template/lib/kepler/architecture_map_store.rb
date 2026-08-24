# frozen_string_literal: true

require_relative "contracts"

module Kepler
  class ArchitectureMapStore
    def initialize(config)
      @config = config
    end

    def load
      raise ValidationError, "architecture map is not configured" unless File.file?(@config.architecture_map_path)
      Contracts.architecture_map!(Support.load_data(@config.architecture_map_path))
    end

    def confirm(source_path)
      value = Support.load_data(source_path)
      value["metadata"] ||= {}
      value["metadata"]["confirmed"] = true
      value["metadata"]["confirmed_at"] = Time.now.utc.iso8601
      Contracts.architecture_map!(value)
      Support.atomic_yaml(@config.architecture_map_path, value)
      { "status" => "confirmed", "path" => Support.relative_path(@config.root, @config.architecture_map_path), "workspaces" => value["workspaces"].keys.sort }
    end
  end
end

# frozen_string_literal: true

require_relative "architecture_map_store"

module Kepler
  # Converts a live Codex project-list snapshot into Kepler's selected-project
  # registry and initial ArchitectureMap. It never scans, clones, opens, or
  # modifies a selected project.
  class SetupStore
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def plan(project_catalog:, project_ids:)
      catalog = load_catalog(project_catalog)
      ids = Array(project_ids).map(&:to_s)
      raise UsageError, "select at least one saved project with --project-id" if ids.empty?
      raise ValidationError, "duplicate --project-id values are not allowed" unless ids.uniq.length == ids.length

      indexed = catalog.fetch("projects").each_with_object({}) do |item, output|
        output[item.fetch("projectId").to_s] = item
      end
      missing = ids.reject { |id| indexed.key?(id) }
      raise ValidationError, "selected project ID is absent from the live catalog: #{missing.join(', ')}" unless missing.empty?

      used_keys = {}
      projects = ids.map do |id|
        normalize_project(indexed.fetch(id), used_keys)
      end
      duplicate_paths = projects.group_by { |item| item["path"] }.select { |_path, items| items.length > 1 }.keys
      raise ValidationError, "multiple selected projects resolve to the same path: #{duplicate_paths.join(', ')}" unless duplicate_paths.empty?

      architecture = architecture_for(projects, confirmed: false)
      {
        "schema_version" => "kepler.setup-plan/v2",
        "read_only" => true,
        "selection_source" => "codex_app.list_projects",
        "display_name_match_accepted" => false,
        "repository_scan_performed" => false,
        "selected_project_mutation" => false,
        "bridges" => {
          "required" => false,
          "installed" => 0,
          "policy" => "optional_advanced"
        },
        "projects" => projects,
        "architecture_map" => architecture,
        "summary" => {
          "catalogued" => catalog.fetch("projects").length,
          "selected" => projects.length,
          "exact_path_verified" => projects.count { |item| item["exact_path_verified"] }
        },
        "next" => "Review the proposed workspace keys and root domains, then run setup apply with the same catalog and IDs plus --confirm."
      }
    end

    def apply(project_catalog:, project_ids:, confirm: false, architecture_map: nil)
      raise UsageError, "setup apply requires --confirm after the ArchitectureMap proposal is reviewed" unless confirm

      value = plan(project_catalog: project_catalog, project_ids: project_ids)
      projects = value.fetch("projects")
      existing_projects = config.project_verifications
      registry = {
        "api_version" => "kepler.dev/v1alpha1",
        "kind" => "CodexProjectVerifications",
        "projects" => projects.each_with_object({}) do |project, output|
          key = project.fetch("logical_key")
          record = {
            "logical_key" => project.fetch("logical_key"),
            "runtime_project_id" => project.fetch("runtime_project_id"),
            "path" => project.fetch("path"),
            "display_name" => project.fetch("display_name"),
            "project_kind" => project.fetch("project_kind"),
            "host_id" => project["host_id"],
            "is_git_repository" => project.fetch("is_git_repository"),
            "verified" => true,
            "verification_source" => "live_project_list_exact_path"
          }.compact
          prior = existing_projects[key]
          record["verified_at"] = same_verified_project?(prior, record) ? prior.fetch("verified_at") : Time.now.utc.iso8601
          output[key] = record
        end
      }
      architecture = if architecture_map
                       confirmed_architecture_from(architecture_map, projects)
                     else
                       architecture_for(projects, confirmed: true)
                     end
      existing_architecture = load_existing_architecture
      if (architecture_map && same_architecture_definition?(existing_architecture, architecture)) ||
         (architecture_map.nil? && same_selected_projects?(existing_architecture, architecture))
        architecture = existing_architecture
      end
      before_registry = File.file?(config.project_registry_path) ? File.read(config.project_registry_path, encoding: "UTF-8") : nil
      before_architecture = File.file?(config.architecture_map_path) ? File.read(config.architecture_map_path, encoding: "UTF-8") : nil
      Support.atomic_yaml(config.project_registry_path, registry)
      Support.atomic_yaml(config.architecture_map_path, architecture)
      Config.new(root: config.root).project_verifications
      ArchitectureMapStore.new(Config.new(root: config.root)).load
      value.merge(
        "schema_version" => "kepler.setup-apply/v2",
        "read_only" => false,
        "status" => "configured",
        "changed" => before_registry != File.read(config.project_registry_path, encoding: "UTF-8") ||
          before_architecture != File.read(config.architecture_map_path, encoding: "UTF-8"),
        "architecture_map" => architecture,
        "next" => "Run /kepler doctor, then /kepler plan."
      )
    rescue StandardError
      restore(config.project_registry_path, before_registry) if defined?(before_registry)
      restore(config.architecture_map_path, before_architecture) if defined?(before_architecture)
      raise
    end

    private

    def load_catalog(path)
      value = Support.load_data(path)
      raise ValidationError, "project catalog must be a mapping" unless value.is_a?(Hash)
      raise ValidationError, "project catalog schemaVersion must be 2" unless value["schemaVersion"].to_i == 2
      projects = value["projects"]
      raise ValidationError, "project catalog projects must be a non-empty array" unless projects.is_a?(Array) && !projects.empty?
      projects.each do |project|
        raise ValidationError, "project catalog entry must be a mapping" unless project.is_a?(Hash)
        %w[projectId path].each do |key|
          raise ValidationError, "project catalog entry is missing #{key}" unless Support.present?(project[key])
        end
      end
      value
    end

    def normalize_project(item, used_keys)
      path = item.fetch("path").to_s
      raise ValidationError, "saved project path must be absolute: #{path}" unless Pathname.new(path).absolute?
      raise ValidationError, "saved project path does not exist: #{path}" unless File.exist?(path)
      raise ValidationError, "saved project path must not be a symlink: #{path}" if File.symlink?(path)
      real_path = File.realpath(path)
      raise ValidationError, "the Kepler control project cannot select itself" if real_path == File.realpath(config.root)

      base = (item["label"] || File.basename(real_path)).to_s.downcase.gsub(/[^a-z0-9._-]+/, "-")
      base = base.gsub(/\A[^a-z0-9]+|[^a-z0-9]+\z/, "")
      base = "project" if base.empty?
      key = base
      suffix = 2
      while used_keys[key]
        key = "#{base}-#{suffix}"
        suffix += 1
      end
      Support.validate_identifier!(key, label: "selected project logical key")
      used_keys[key] = true
      {
        "logical_key" => key,
        "runtime_project_id" => item.fetch("projectId").to_s,
        "display_name" => (item["label"] || File.basename(real_path)).to_s,
        "path" => real_path,
        "project_kind" => (item["projectKind"] || "local").to_s,
        "host_id" => item["hostId"],
        "is_git_repository" => item["isGitRepository"] == true,
        "exact_path_verified" => real_path == File.realpath(item.fetch("path").to_s)
      }.compact
    rescue Errno::ENOENT, Errno::ELOOP => e
      raise ValidationError, "saved project path cannot be resolved safely: #{e.message}"
    end

    def architecture_for(projects, confirmed:)
      {
        "api_version" => Contracts::API_VERSION,
        "kind" => "ArchitectureMap",
        "metadata" => {
          "confirmed" => confirmed,
          "confirmation_source" => confirmed ? "explicit_setup_apply_confirm" : "pending_user_review",
          "generated_at" => Time.now.utc.iso8601
        },
        "workspaces" => projects.each_with_object({}) do |project, output|
          output[project.fetch("logical_key")] = {
            "codex_project" => project.fetch("logical_key"),
            "project_path" => project.fetch("path"),
            "runtime_project_id" => project.fetch("runtime_project_id"),
            "domains" => {
              "root" => {
                "paths" => ["."],
                "facts" => ["Default non-exclusive domain; refine paths and relationships when the work requires it."]
              }
            }
          }
        end,
        "relationships" => {}
      }
    end

    def same_verified_project?(prior, current)
      return false unless prior.is_a?(Hash)

      fields = %w[
        logical_key runtime_project_id path display_name project_kind host_id
        is_git_repository verified verification_source
      ]
      fields.all? { |field| prior[field] == current[field] }
    end

    def load_existing_architecture
      return nil unless File.file?(config.architecture_map_path)

      value = Support.load_data(config.architecture_map_path)
      return nil unless value.is_a?(Hash)
      return nil unless value.dig("metadata", "confirmed") == true

      value
    rescue ValidationError
      nil
    end

    def same_selected_projects?(prior, proposed)
      return false unless prior.is_a?(Hash)

      prior_workspaces = prior["workspaces"]
      proposed_workspaces = proposed.fetch("workspaces")
      return false unless prior_workspaces.is_a?(Hash)
      return false unless prior_workspaces.keys.sort == proposed_workspaces.keys.sort

      prior_workspaces.all? do |key, workspace|
        proposed_workspace = proposed_workspaces.fetch(key)
        %w[codex_project project_path runtime_project_id].all? do |field|
          workspace[field] == proposed_workspace[field]
        end
      end
    end

    def same_architecture_definition?(prior, proposed)
      return false unless prior.is_a?(Hash)

      %w[api_version kind workspaces relationships].all? do |field|
        prior[field] == proposed[field]
      end
    end

    def confirmed_architecture_from(path, projects)
      value = Support.load_data(path)
      raise ValidationError, "ArchitectureMap proposal must be a mapping" unless value.is_a?(Hash)

      value["metadata"] ||= {}
      value["metadata"]["confirmed"] = true
      value["metadata"]["confirmation_source"] = "explicit_setup_apply_confirmed_file"
      value["metadata"]["confirmed_at"] = Time.now.utc.iso8601
      Contracts.architecture_map!(value)

      expected = projects.each_with_object({}) do |project, output|
        output[project.fetch("logical_key")] = project
      end
      workspaces = value.fetch("workspaces")
      unless workspaces.keys.sort == expected.keys.sort
        raise ValidationError, "ArchitectureMap workspace set must equal the selected project set"
      end
      workspaces.each do |key, workspace|
        project = expected.fetch(key)
        unless workspace["codex_project"] == key &&
               workspace["runtime_project_id"] == project["runtime_project_id"] &&
               File.realpath(workspace["project_path"]) == project["path"]
          raise ValidationError, "ArchitectureMap identity conflicts with selected project: #{key}"
        end
      end
      value
    rescue Errno::ENOENT, Errno::ELOOP => e
      raise ValidationError, "ArchitectureMap project path cannot be resolved safely: #{e.message}"
    end

    def restore(path, content)
      if content
        Support.atomic_write(path, content)
      else
        FileUtils.rm_f(path)
      end
    end
  end
end

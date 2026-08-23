# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

require "kepler/bridge_store"
require "kepler/bridge_bulk_store"
require "kepler/architecture_map_store"
require "kepler/cli"
require "kepler/config"
require "kepler/doctor"
require "kepler/repo_planner"
require "kepler/repository_store"
require "kepler/route_planner"
require "kepler/setup_store"
require "kepler/plan_store"
require "kepler/memory_store"

class KeplerTest < Minitest::Test
  TEMPLATE_ROOT = File.expand_path("..", __dir__)
  CONTROL_PLANE_ENTRIES = %w[
    .gitignore AGENTS.md Makefile README.md bin docs kepler.yaml lib scripts tests
  ].freeze
  HUB_CONTROL_PLANE_ENTRIES = %w[
    automations bridges compatibility.json repositories.yaml schemas templates
  ].freeze
  WORKLOAD_ROOTS = %w[charts development environments patching research].freeze

  def with_hub
    Dir.mktmpdir("kepler-test-") do |directory|
      root = File.join(directory, "hub")
      FileUtils.mkdir_p(root)
      CONTROL_PLANE_ENTRIES.each do |entry|
        FileUtils.cp_r(File.join(TEMPLATE_ROOT, entry), File.join(root, entry))
      end
      FileUtils.mkdir_p(File.join(root, "hub"))
      HUB_CONTROL_PLANE_ENTRIES.each do |entry|
        source = File.join(TEMPLATE_ROOT, "hub", entry)
        FileUtils.cp_r(source, File.join(root, "hub", entry)) if File.exist?(source)
      end
      Kepler::Support.atomic_yaml(
        File.join(root, "hub", "repositories.yaml"),
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "RepositoryDeclarations",
          "schema" => "hub/schemas/repository-declarations.schema.json",
          "repositories" => []
        }
      )
      WORKLOAD_ROOTS.each do |workload|
        FileUtils.mkdir_p(File.join(root, workload))
        readme = File.join(TEMPLATE_ROOT, workload, "README.md")
        FileUtils.cp(readme, File.join(root, workload, "README.md")) if File.file?(readme)
      end
      FileUtils.mkdir_p(File.join(root, "compliance"))
      %w[README.md _program-template].each do |entry|
        source = File.join(TEMPLATE_ROOT, "compliance", entry)
        FileUtils.cp_r(source, File.join(root, "compliance", entry)) if File.exist?(source)
      end
      config_path = File.join(root, "kepler.yaml")
      File.write(config_path, File.read(config_path).gsub("__KEPLER_ROOT__", root))
      yield root, Kepler::Config.new(root: root)
    end
  end

  def git(*arguments, chdir:)
    output, error, status = Open3.capture3({ "LC_ALL" => "C" }, "git", *arguments, chdir: chdir)
    raise "#{arguments.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  def initialize_repository(root, name = "sample")
    path = File.join(root, "development", name)
    FileUtils.mkdir_p(path)
    git("init", "--quiet", "--initial-branch=main", path, chdir: root)
    File.write(File.join(path, "AGENTS.md"), "# Repository policy\n")
    path
  end

  def commit_repository(path)
    git("config", "user.name", "Synthetic Test", chdir: path)
    git("config", "user.email", "test@example.invalid", chdir: path)
    git("add", "AGENTS.md", chdir: path)
    git("commit", "--quiet", "-m", "Synthetic fixture", chdir: path)
  end

  def register_repository(config, id, path, mode: "reference")
    registry = File.file?(config.local_registry_path) ? Kepler::Support.load_data(config.local_registry_path) : {
      "api_version" => "kepler.dev/v1alpha1",
      "kind" => "LocalRepositoryRegistry",
      "repositories" => {}
    }
    registry["repositories"][id] = {
      "local_path" => Kepler::Support.relative_path(config.root, path),
      "provider" => "existing-local",
      "locator" => path,
      "owner" => "local",
      "default_branch" => "main",
      "default_branch_verified" => true,
      "workload_ids" => ["development"],
      "bridge_profile" => "application",
      "bridge_mode" => mode,
      "codex_project_key" => id,
      "codex_project_expectation" => "saved_exact_path"
    }
    Kepler::Support.atomic_yaml(config.local_registry_path, registry)
    Kepler::Config.new(root: config.root)
  end

  def write_declarations(config, entries)
    Kepler::Support.atomic_yaml(
      config.repository_declarations_path,
      {
        "api_version" => "kepler.dev/v1alpha1",
        "kind" => "RepositoryDeclarations",
        "schema" => "hub/schemas/repository-declarations.schema.json",
        "repositories" => entries
      }
    )
    Kepler::Config.new(root: config.root)
  end

  def declaration(id, path, mode: "reference")
    {
      "id" => id,
      "workload" => "development",
      "provider" => "existing-local",
      "locator" => File.join("development", File.basename(path)),
      "local_path" => File.join("development", File.basename(path)),
      "owner" => "local",
      "default_branch" => "main",
      "default_branch_verified" => true,
      "bridge" => {
        "profile" => "application",
        "mode" => mode
      },
      "codex_project" => {
        "expectation" => "saved_exact_path",
        "logical_key" => id
      }
    }
  end

  def test_providers_are_loadable
    with_hub do |_root, config|
      assert_equal %w[bitbucket existing-local git github gitlab remote-validation], config.providers.keys.sort
    end
  end

  def test_read_only_plans_do_not_write
    with_hub do |root, config|
      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      route = Kepler::RoutePlanner.new(config).plan(
        workload_name: "development", work_type: "implementation"
      )
      repo = Kepler::RepoPlanner.new(config).plan(
        workload_name: "development", provider_name: "github", locator: "example/service"
      )
      after = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort
      assert route["plan_read_only"]
      assert repo["plan_read_only"]
      assert_equal before, after
    end
  end

  def test_remote_validation_plan_is_non_cloning
    with_hub do |_root, config|
      plan = Kepler::RepoPlanner.new(config).plan(
        workload_name: "environments",
        provider_name: "remote-validation",
        locator: "configured-runtime-project"
      )
      assert plan["plan_read_only"]
      assert_equal "configured-runtime-project", plan["target"]
      refute plan["steps"].any? { |step| step.downcase.include?("clone") }
      assert_raises(Kepler::ValidationError) do
        Kepler::RepositoryStore.new(config).onboard(
          workload_name: "environments",
          provider_name: "remote-validation",
          locator: "configured-runtime-project",
          repository_id: "runtime"
        )
      end
    end
  end

  def test_remote_project_routes_in_remote_mode
    with_hub do |root, _config|
      value = Kepler::Support.load_data(File.join(root, "kepler.yaml"))
      value["codex_projects"]["runtime"] = {
        "display_name" => "Runtime Validation",
        "context" => "remote",
        "path" => File.join(root, "environments"),
        "role" => "runtime_validation",
        "workload_id" => "environments",
        "required" => false
      }
      Kepler::Support.atomic_yaml(File.join(root, "kepler.yaml"), value)
      config = Kepler::Config.new(root: root)
      Kepler::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "runtime" => {
              "logical_key" => "runtime",
              "runtime_project_id" => "opaque-runtime-project-42",
              "path" => File.join(root, "environments"),
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-01-01T00:00:00Z"
            }
          }
        }
      )
      plan = Kepler::RoutePlanner.new(Kepler::Config.new(root: root)).plan(
        workload_name: "environments",
        work_type: "runtime_validation",
        project_key: "runtime"
      )
      assert_equal "remote", plan["mode"]
      assert_equal "runtime", plan["project_key"]
      assert_equal "opaque-runtime-project-42", plan["runtime_project_id"]
      assert plan["dispatch_ready"]
      assert plan["dispatch_required"]
      assert plan["stop_after_dispatch"]
      prompt_requirements = plan.fetch("child_prompt_requirements").join(" ")
      assert_includes prompt_requirements, "lead Kepler skill"
      assert_includes prompt_requirements, "owning workload"
      assert_includes prompt_requirements, "new evidence crosses domains"
      assert_includes prompt_requirements, "before domain-specific mutation"
    end
  end

  def test_contained_paths_reject_escape
    with_hub do |root, config|
      assert_raises(Kepler::ConfigurationError) { config.root_path("../outside") }
      Dir.mktmpdir("outside-hub-") do |outside|
        link = File.join(root, "development", "outside-link")
        File.symlink(outside, link)
        assert_raises(Kepler::ConfigurationError) do
          config.root_path("development/outside-link/new-repository")
        end
      end
    end
  end

  def test_bridge_modes_record_integrity_and_idempotent_noop
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      store = Kepler::BridgeStore.new(config)
      plan = store.plan(repository_id: "sample", mode: "reference", profile: "application")
      assert plan["read_only"]
      record = store.install(repository_id: "sample", mode: "reference", profile: "application")
      assert_equal Digest::SHA256.file(File.join(repository, record["target"])).hexdigest, record["sha256"]
      second = store.install(repository_id: "sample", mode: "reference", profile: "application")
      assert_equal "noop", second["action"]
      assert_equal true, second["verified"]
    end
  end

  def test_materialized_bridge_is_local_and_repo_native_requires_acknowledgement
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      store = Kepler::BridgeStore.new(config)
      record = store.install(repository_id: "sample", mode: "materialized", profile: "application")
      assert_equal ".kepler/bridge/AGENTS.md", record["target"]
      policy = File.read(File.join(repository, record["target"]))
      assert_includes policy, "Bridge mode: `materialized`"
      refute_includes policy, root
      refute_includes policy, repository
      assert_equal true, record["portable"]
      assert record["artifacts"].any? { |item| item["path"] == ".kepler/bridge/docs/workflow.md" }
      assert_raises(Kepler::UsageError) do
        store.install(repository_id: "sample", mode: "repo-native", profile: "application")
      end
    end
  end

  def test_worktree_route_hands_off_verified_ignored_bridge_from_original_checkout
    with_hub do |root, config|
      repository = initialize_repository(root, "worktree-handoff")
      commit_repository(repository)
      config = register_repository(config, "worktree-handoff", repository, mode: "materialized")
      config = write_declarations(
        config,
        [declaration("worktree-handoff", repository, mode: "materialized")]
      )
      record = Kepler::BridgeStore.new(config).install(
        repository_id: "worktree-handoff",
        mode: "materialized",
        profile: "application"
      )
      Kepler::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "worktree-handoff" => {
              "logical_key" => "worktree-handoff",
              "runtime_project_id" => "opaque-runtime-worktree-42",
              "path" => repository,
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-01-01T00:00:00Z"
            }
          }
        }
      )

      plan = Kepler::RoutePlanner.new(Kepler::Config.new(root: root)).plan(
        workload_name: "development",
        work_type: "implementation",
        repository_id: "worktree-handoff"
      )
      handoff = plan.fetch("bridge_handoff")
      assert_equal "verified", handoff["status"]
      assert_equal "materialized", handoff["mode"]
      assert_equal File.realpath(repository), handoff["original_checkout_path"]
      assert_equal File.realpath(File.join(repository, record["target"])), handoff["bridge_target_path"]
      assert_equal record["sha256"], handoff["bridge_target_sha256"]
      assert_equal(
        "read_verified_bridge_from_original_checkout_when_ignored_target_absent",
        handoff["worktree_policy"]
      )
      assert_equal false, handoff["copy_into_worktree"]
      assert handoff["artifacts"].all? { |artifact| File.absolute_path(artifact["path"]) == artifact["path"] }
      assert handoff["artifacts"].any? do |artifact|
        artifact["relative_path"] == ".kepler/bridge/docs/workflow.md"
      end
      assert_includes plan["child_prompt_requirements"].join(" "), "original_checkout_path"
    end
  end

  def test_repository_route_refuses_missing_bridge
    with_hub do |root, config|
      repository = initialize_repository(root, "missing-bridge")
      commit_repository(repository)
      config = register_repository(config, "missing-bridge", repository)
      config = write_declarations(config, [declaration("missing-bridge", repository)])

      error = assert_raises(Kepler::ValidationError) do
        Kepler::RoutePlanner.new(config).plan(
          workload_name: "development",
          work_type: "implementation",
          repository_id: "missing-bridge"
        )
      end
      assert_includes error.message, "bridge must be installed and verified"
    end
  end

  def test_repo_native_bridge_preserves_existing_instructions
    with_hub do |root, config|
      repository = initialize_repository(root)
      commit_repository(repository)
      original = File.read(File.join(repository, "AGENTS.md"))
      config = register_repository(config, "sample", repository)
      record = Kepler::BridgeStore.new(config).install(
        repository_id: "sample",
        mode: "repo-native",
        profile: "application",
        acknowledge_repo_native: true
      )
      updated = File.read(File.join(repository, "AGENTS.md"))
      assert updated.start_with?(original.rstrip)
      assert_includes updated, "<!-- kepler-bridge:1.0.0 -->"
      assert_includes updated, "Bridge mode: `repo-native`"
      refute_includes updated, root
      refute_includes updated, repository
      assert_includes updated, "Repository rules own"
      assert_equal true, record["portable"]
      assert_equal "AGENTS.md", record["target"]
    end
  end

  def test_doctor_detects_absolute_path_in_portable_bridge
    with_hub do |root, config|
      repository = initialize_repository(root)
      commit_repository(repository)
      config = register_repository(config, "sample", repository)
      record = Kepler::BridgeStore.new(config).install(
        repository_id: "sample",
        mode: "repo-native",
        profile: "application",
        acknowledge_repo_native: true
      )
      path = File.join(repository, record["target"])
      File.write(path, "#{File.read(path)}\nMachine path: /Users/example/private/hub\n")
      result = Kepler::Doctor.new(Kepler::Config.new(root: root)).run
      assert_includes result["issues"].map { |item| item["code"] }, "bridge.absolute_path_leak"
    end
  end

  def test_existing_local_onboarding_preserves_dirty_state
    with_hub do |root, config|
      repository = initialize_repository(root)
      commit_repository(repository)
      File.write(File.join(repository, "local-note.txt"), "preserve me\n")
      result = Kepler::RepositoryStore.new(config).onboard(
        workload_name: "development",
        provider_name: "existing-local",
        locator: repository,
        repository_id: "sample",
        bridge_mode: "reference",
        bridge_profile: "application"
      )
      assert_equal false, result.dig("verification", "clean")
      assert_includes result.dig("verification", "changes"), "?? local-note.txt"
      assert_equal "preserve me\n", File.read(File.join(repository, "local-note.txt"))
      registered = Kepler::Config.new(root: root).repository("sample")
      assert_equal "local", registered["owner"]
      assert_equal result.dig("verification", "branch"), registered["default_branch"]
      assert_equal false, result.dig("project_registration", "verified")
    end
  end

  def test_setup_plan_discovers_attached_repository_without_writing
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "attached-service")
      commit_repository(repository)
      File.write(File.join(repository, "local-note.txt"), "preserve me\n")
      declarations_before = File.read(config.repository_declarations_path)

      result = Kepler::SetupStore.new(config).plan(
        repositories_root: repositories_root
      )

      assert_equal true, result["read_only"]
      assert_equal 1, result.dig("summary", "discovered")
      assert_equal 1, result.dig("summary", "ready")
      item = result.fetch("repositories").first
      assert_equal "attached", item["placement"]
      assert_equal "reference", item.dig("bridge", "mode")
      assert_equal false, item["clean"]
      assert_equal "existing-local", item["provider"]
      assert_equal "attached", item.dig("proposed_declaration", "placement")
      refute item.fetch("proposed_declaration").key?("local_path")
      assert_equal declarations_before, File.read(config.repository_declarations_path)
      refute File.exist?(config.local_registry_path)
      refute File.exist?(File.join(repository, "AGENTS.override.md"))
    end
  end

  def test_setup_plan_normalizes_hosted_origin_without_network_access
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "hosted-service")
      commit_repository(repository)
      git(
        "remote", "add", "origin",
        "https://github.com/example-company/hosted-service.git",
        chdir: repository
      )

      item = Kepler::SetupStore.new(config).plan(
        repositories_root: repositories_root
      ).fetch("repositories").first

      assert_equal "github", item["provider"]
      assert_equal "example-company/hosted-service", item["locator"]
      assert_equal "example-company", item["owner"]
      assert_equal "main", item["verified_default_branch"]
      assert_equal "checked_out_branch_fallback", item["default_branch_source"]
      assert_equal false, item["default_branch_verified"]
      assert_includes item.fetch("warnings").join(" "), "unverified fallback"

      git("update-ref", "refs/remotes/origin/main", "HEAD", chdir: repository)
      git(
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/main",
        chdir: repository
      )
      verified = Kepler::SetupStore.new(config).plan(
        repositories_root: repositories_root
      ).fetch("repositories").first
      assert_equal "origin_head", verified["default_branch_source"]
      assert_equal true, verified["default_branch_verified"]
    end
  end

  def test_setup_plan_blocks_and_redacts_credential_bearing_origin
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "credential-service")
      commit_repository(repository)
      git(
        "remote", "add", "origin",
        "https://synthetic-user:synthetic-secret@example.invalid/service.git",
        chdir: repository
      )

      result = Kepler::SetupStore.new(config).plan(
        repositories_root: repositories_root
      )
      item = result.fetch("repositories").first
      serialized = JSON.generate(result)

      assert_equal "blocked", item["status"]
      assert_includes item.fetch("blockers").join(" "), "embedded credentials"
      refute_includes serialized, "synthetic-user"
      refute_includes serialized, "synthetic-secret"
    end
  end

  def test_setup_connect_keeps_unverified_remote_default_branch_truthful
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "branch-fallback-service")
      commit_repository(repository)
      git(
        "remote", "add", "origin",
        "https://github.com/example-company/branch-fallback-service.git",
        chdir: repository
      )

      result = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"], result.inspect
      declaration = Kepler::Config.new(root: root).repository_declarations.first
      assert_equal false, declaration["default_branch_verified"]
      assert_equal "main", declaration["default_branch"]
      doctor = Kepler::Doctor.new(Kepler::Config.new(root: root)).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor.inspect
      assert_includes(
        doctor["issues"].map { |item| item["code"] },
        "repository.default_branch_pending"
      )
    end
  end

  def test_setup_connect_never_persists_local_file_origin_in_portable_declaration
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "local-origin-service")
      commit_repository(repository)
      local_origin = File.join(File.dirname(root), "synthetic-origin.git")
      git("remote", "add", "origin", "file://#{local_origin}", chdir: repository)

      result = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"], result.inspect
      declaration = Kepler::Config.new(root: root).repository_declarations.first
      assert_equal "existing-local", declaration["provider"]
      assert_equal "local-origin-service", declaration["locator"]
      serialized = File.read(config.repository_declarations_path)
      refute_includes serialized, local_origin
      refute_includes serialized, File.dirname(root)
    end
  end

  def test_setup_connect_attaches_in_place_and_installs_safe_reference_bridge
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "attached-service")
      commit_repository(repository)
      agents_before = File.read(File.join(repository, "AGENTS.md"))

      result = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"], result.inspect
      assert_equal "connected_projects_pending", result["status"]
      assert_equal 1, result.dig("summary", "connected")
      assert_equal 1, result.dig("summary", "project_pending")
      declaration = Kepler::Config.new(root: root).repository_declarations.first
      assert_equal "attached", declaration["placement"]
      refute declaration.key?("local_path")
      refute_includes File.read(config.repository_declarations_path), repository
      registered = Kepler::Config.new(root: root).repository("attached-service")
      assert_equal File.realpath(repository), File.realpath(registered["path"])
      assert_equal "attached", registered["placement"]
      assert File.file?(File.join(repository, "AGENTS.override.md"))
      _ignored, _error, ignored_status = Kepler::Support.capture(
        "git", "check-ignore", "-q", "--", "AGENTS.override.md", chdir: repository
      )
      assert_equal 0, ignored_status
      assert_equal agents_before, File.read(File.join(repository, "AGENTS.md"))
      doctor = Kepler::Doctor.new(Kepler::Config.new(root: root)).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor.inspect
      bridge_registry = File.read(config.bridge_registry_path)
      second = Kepler::SetupStore.new(Kepler::Config.new(root: root)).connect(
        repositories_root: repositories_root
      )
      assert_equal true, second["ok"], second.inspect
      assert_equal false, second["changed"]
      assert_equal "noop", second.dig("bridge_receipt", "repositories", 0, "bridge", "status")
      assert_equal bridge_registry, File.read(config.bridge_registry_path)
    end
  end

  def test_setup_connect_skips_unmanaged_override_without_writing_state
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      repository = initialize_repository(repositories_root, "conflict-service")
      commit_repository(repository)
      File.write(File.join(repository, "AGENTS.override.md"), "unmanaged\n")
      declarations_before = File.read(config.repository_declarations_path)

      result = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal false, result["ok"]
      assert_equal false, result["changed"]
      assert_equal "connected_with_blockers", result["status"]
      assert_includes(
        result.fetch("repositories").first.fetch("blockers").join(" "),
        "refusing to overwrite"
      )
      assert_equal declarations_before, File.read(config.repository_declarations_path)
      refute File.exist?(config.local_registry_path)
      assert_equal "unmanaged\n", File.read(File.join(repository, "AGENTS.override.md"))

      stopped = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root,
        failure_policy: "stop"
      )
      assert_equal "stopped_before_changes", stopped["status"]
      assert_equal 0, stopped.dig("summary", "project_verified")
    end
  end

  def test_setup_connect_reports_empty_authorized_root_without_claiming_ready
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "empty-repositories")
      FileUtils.mkdir_p(repositories_root)

      result = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root
      )

      assert_equal true, result["ok"]
      assert_equal false, result["complete"]
      assert_equal "no_repositories_found", result["status"]
      assert_equal 0, result.dig("summary", "connected")
      assert_equal false, result["changed"]
    end
  end

  def test_setup_connect_continues_independent_safe_repositories
    with_hub do |root, config|
      repositories_root = File.join(File.dirname(root), "repositories")
      safe = initialize_repository(repositories_root, "a-safe-service")
      blocked = initialize_repository(repositories_root, "b-blocked-service")
      [safe, blocked].each { |repository| commit_repository(repository) }
      File.write(File.join(blocked, "AGENTS.override.md"), "unmanaged\n")

      result = Kepler::SetupStore.new(config).connect(
        repositories_root: repositories_root,
        failure_policy: "continue"
      )

      assert_equal false, result["ok"]
      assert_equal 1, result.dig("summary", "connected")
      assert_equal 1, result.dig("summary", "blocked")
      assert File.file?(File.join(safe, "AGENTS.override.md"))
      assert_equal "unmanaged\n", File.read(File.join(blocked, "AGENTS.override.md"))
      declarations = Kepler::Config.new(root: root).repository_declarations
      assert_equal ["a-safe-service"], declarations.map { |item| item["id"] }
      doctor = Kepler::Doctor.new(Kepler::Config.new(root: root)).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor.inspect
    end
  end

  def test_doctor_detects_bridge_drift
    with_hub do |root, config|
      repository = initialize_repository(root)
      config = register_repository(config, "sample", repository)
      record = Kepler::BridgeStore.new(config).install(
        repository_id: "sample", mode: "reference", profile: "application"
      )
      File.write(File.join(repository, record["target"]), "changed\n")
      result = Kepler::Doctor.new(Kepler::Config.new(root: root)).run
      assert_includes result["issues"].map { |item| item["code"] }, "bridge.drift"
      assert result["no_fetch"]
    end
  end

  def test_doctor_and_status_report_missing_registered_repository_with_bridge
    with_hub do |root, config|
      repository = initialize_repository(root, "missing-bridged-service")
      commit_repository(repository)
      config = register_repository(config, "missing-bridged-service", repository)
      Kepler::BridgeStore.new(config).install(
        repository_id: "missing-bridged-service",
        mode: "reference",
        profile: "application"
      )
      FileUtils.rm_rf(repository)
      config = Kepler::Config.new(root: root)

      result = Kepler::Doctor.new(config).run
      codes = result.fetch("issues").map { |item| item.fetch("code") }
      assert_includes codes, "repo.unavailable"
      assert_includes codes, "bridge.repository_unavailable"

      doctor_output = StringIO.new
      doctor_status = Kepler::CLI.new(
        root: root,
        out: doctor_output,
        err: StringIO.new
      ).run(["doctor", "--json"])
      assert_equal 1, doctor_status
      doctor_result = JSON.parse(doctor_output.string)
      assert_includes doctor_result.fetch("issues").map { |item| item.fetch("code") }, "repo.unavailable"
      assert_includes doctor_result.fetch("issues").map { |item| item.fetch("code") }, "bridge.repository_unavailable"

      status_output = StringIO.new
      status_status = Kepler::CLI.new(
        root: root,
        out: status_output,
        err: StringIO.new
      ).run(["status", "--json"])
      assert_equal 0, status_status
      status_result = JSON.parse(status_output.string)
      assert_includes status_result.fetch("issues").map { |item| item.fetch("code") }, "repo.unavailable"
      assert_includes status_result.fetch("issues").map { |item| item.fetch("code") }, "bridge.repository_unavailable"
    end
  end

  def test_command_capture_normalizes_missing_working_directory
    with_hub do |root, _config|
      missing = File.join(root, "missing-working-directory")

      output, error, status = Kepler::Support.capture(
        "git", "status", chdir: missing
      )

      assert_equal "", output
      assert_equal "working directory is unavailable", error
      assert_equal 127, status
    end
  end

  def test_compliance_working_records_require_semantic_parity
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "working-records")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "control.json"), JSON.pretty_generate({ "status" => "not_assessed" }))
      File.write(File.join(directory, "control.yaml"), YAML.dump({ "status" => "not_assessed" }))
      first = Kepler::Doctor.new(config).run
      assert_equal true, first.dig("compliance", "pairs", 0, "equivalent")

      File.write(File.join(directory, "control.yaml"), YAML.dump({ "status" => "satisfied" }))
      second = Kepler::Doctor.new(config).run
      assert_includes second["issues"].map { |item| item["code"] }, "compliance.sidecar_mismatch"
    end
  end

  def test_compliance_sidecars_accept_safe_yaml_aliases
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      value = {
        "controls" => [
          { "id" => "AC-1", "status" => "satisfied" },
          { "id" => "AC-1", "status" => "satisfied" }
        ]
      }
      File.write(File.join(directory, "control.json"), JSON.pretty_generate(value))
      File.write(
        File.join(directory, "control.yaml"),
        "---\ncontrols:\n- &control\n  id: AC-1\n  status: satisfied\n- *control\n"
      )

      result = Kepler::Doctor.new(config).run
      assert_equal true, result.dig("compliance", "pairs", 0, "equivalent")
      refute_includes result["issues"].map { |item| item["code"] }, "compliance.invalid_yaml"
      refute_includes result["issues"].map { |item| item["code"] }, "compliance.sidecar_mismatch"
    end
  end

  def test_compliance_parse_failure_does_not_duplicate_mismatch
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "control.json"), JSON.pretty_generate({ "status" => "satisfied" }))
      File.write(File.join(directory, "control.yaml"), "status: [\n")

      result = Kepler::Doctor.new(config).run
      codes = result["issues"].map { |item| item["code"] }
      assert_includes codes, "compliance.invalid_yaml"
      refute_includes codes, "compliance.sidecar_mismatch"
      assert_nil result.dig("compliance", "pairs", 0, "equivalent")
    end
  end

  def test_compliance_rejects_recursive_yaml_aliases_without_crashing
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "control-assessments")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "control.json"), JSON.pretty_generate({ "status" => "satisfied" }))
      File.write(
        File.join(directory, "control.yaml"),
        "---\ncycle: &cycle\n  self: *cycle\n"
      )

      result = Kepler::Doctor.new(config).run
      codes = result["issues"].map { |item| item["code"] }
      assert_includes codes, "compliance.invalid_yaml"
      refute_includes codes, "compliance.sidecar_mismatch"
    end
  end

  def test_compliance_allows_standalone_cyclonedx_json
    with_hub do |root, config|
      directory = File.join(root, "compliance", "example", "generated-documents")
      FileUtils.mkdir_p(directory)
      File.write(
        File.join(directory, "sbom.cdx.json"),
        JSON.pretty_generate(
          {
            "bomFormat" => "CycloneDX",
            "specVersion" => "1.6",
            "version" => 1,
            "components" => []
          }
        )
      )

      result = Kepler::Doctor.new(config).run
      refute_includes result["issues"].map { |item| item["code"] }, "compliance.orphan_json"
    end
  end

  def test_doctor_reports_handoff_placeholders
    with_hub do |root, config|
      handoff = File.join(root, "handoffs", "sample.md")
      FileUtils.mkdir_p(File.dirname(handoff))
      File.write(handoff, "# Handoff\n\nOwner: TBD\n")
      result = Kepler::Doctor.new(config).run
      issue = result["issues"].find { |item| item["code"] == "handoff.placeholder" }
      refute_nil issue
      assert_equal "warning", issue["severity"]
      assert_equal "handoffs/sample.md", issue["scope"]
      assert_match(/\A[0-9a-f]{20}\z/, issue["fingerprint"])
    end
  end

  def test_all_automation_templates_are_disabled
    with_hub do |root, _config|
      Dir.glob(File.join(root, "hub", "automations", "*.yaml")).each do |path|
        value = YAML.safe_load(File.read(path), aliases: false)
        assert_equal false, value["enabled"], path
        assert_equal "explicit_user_enablement", value.dig("activation", "policy"), path
      end
    end
  end

  def test_cli_help_documents_read_only_and_state_changing_surfaces
    with_hub do |root, _config|
      output = StringIO.new
      status = Kepler::CLI.new(root: root, out: output, err: StringIO.new).run(["help"])
      assert_equal 0, status
      assert_includes output.string, "route plan"
      assert_includes output.string, "repo onboard"
      assert_includes output.string, "explicit state-changing names"
    end
  end

  def test_repo_plan_json_is_machine_readable
    with_hub do |root, _config|
      output = StringIO.new
      status = Kepler::CLI.new(root: root, out: output, err: StringIO.new).run(
        %w[repo plan --workload development --provider github --repo example/service --json]
      )
      assert_equal 0, status
      value = JSON.parse(output.string)
      assert_equal true, value["plan_read_only"]
      assert_equal "github", value["provider"]
      assert_equal "example", value["owner"]
      assert_equal ["default_branch"], value["resolution_required"]
    end
  end

  def test_provider_adapters_build_safe_urls_without_credentials
    with_hub do |_root, config|
      store = Kepler::RepositoryStore.new(config)
      {
        "github" => "https://github.com/example/service.git",
        "gitlab" => "https://gitlab.com/example/service.git",
        "bitbucket" => "https://bitbucket.org/example/service.git"
      }.each do |provider_name, expected|
        actual = store.send(
          :resolve_url, config.provider(provider_name), "example/service", nil
        )
        assert_equal expected, actual
      end
      assert_equal(
        "file:///tmp/synthetic-repository",
        store.send(
          :resolve_url,
          config.provider("git"),
          "file:///tmp/synthetic-repository",
          nil
        )
      )
      assert_raises(Kepler::ValidationError) do
        store.send(
          :resolve_url,
          config.provider("git"),
          "https://user:secret@example.invalid/service.git",
          nil
        )
      end
      assert_raises(Kepler::ValidationError) do
        store.send(
          :resolve_url,
          config.provider("git"),
          "http://example.invalid/service.git",
          nil
        )
      end
    end
  end

  def test_bulk_bridge_plan_is_read_only_and_reports_exact_inputs
    with_hub do |root, config|
      repository = initialize_repository(root, "bulk-plan")
      commit_repository(repository)
      config = register_repository(config, "bulk-plan", repository)
      config = write_declarations(config, [declaration("bulk-plan", repository)])
      before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
        [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
      end

      plan = Kepler::BridgeBulkStore.new(config).plan

      after = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
        [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
      end
      assert_equal before, after
      assert_equal true, plan["read_only"]
      item = plan.fetch("repositories").first
      assert_equal repository, item["git_root"]
      assert_equal "AGENTS.md", item.fetch("existing_agents_files").first["path"]
      assert_equal "reference", item.dig("bridge", "mode")
      assert_equal ["AGENTS.override.md"], item.dig("bridge", "targets")
      assert_equal "pending", item.dig("project_registration", "status")
    end
  end

  def test_bulk_bridge_install_is_safe_idempotent_and_writes_per_repo_receipts
    with_hub do |root, config|
      reference = initialize_repository(root, "bulk-reference")
      materialized = initialize_repository(root, "bulk-materialized")
      [reference, materialized].each { |path| commit_repository(path) }
      config = register_repository(config, "bulk-reference", reference)
      config = register_repository(config, "bulk-materialized", materialized, mode: "materialized")
      config = write_declarations(
        config,
        [
          declaration("bulk-reference", reference),
          declaration("bulk-materialized", materialized, mode: "materialized")
        ]
      )
      store = Kepler::BridgeBulkStore.new(config)
      first = store.install_all(failure_policy: "continue")
      assert_equal true, first["ok"], first.inspect
      assert_equal false, first["complete"]
      assert_equal 2, first.dig("summary", "installed")
      assert_equal %w[installed installed], first["repositories"].map { |item| item.dig("bridge", "status") }
      assert first["repositories"].all? { |item| item["project_registration"]["status"] == "pending" }
      assert File.file?(config.bridge_setup_receipt_path)
      bridge_registry = File.read(config.bridge_registry_path)

      second = store.install_all(failure_policy: "continue")
      assert_equal true, second["ok"]
      assert_equal 2, second.dig("summary", "noop")
      assert_equal bridge_registry, File.read(config.bridge_registry_path)
      materialized_policy = File.read(File.join(materialized, ".kepler", "bridge", "AGENTS.md"))
      refute_includes materialized_policy, root
      refute_includes materialized_policy, materialized
    end
  end

  def test_bulk_bridge_conflict_refuses_overwrite_and_continue_policy_is_explicit
    with_hub do |root, config|
      conflict = initialize_repository(root, "a-conflict")
      safe = initialize_repository(root, "b-safe")
      [conflict, safe].each { |path| commit_repository(path) }
      File.write(File.join(conflict, "AGENTS.override.md"), "unmanaged instructions\n")
      config = register_repository(config, "a-conflict", conflict)
      config = register_repository(config, "b-safe", safe)
      config = write_declarations(
        config,
        [declaration("a-conflict", conflict), declaration("b-safe", safe)]
      )
      store = Kepler::BridgeBulkStore.new(config)
      plan = store.plan(failure_policy: "continue")
      assert_equal "blocked", plan["repositories"].first["status"]
      assert_includes(
        plan["repositories"].first["overwrite_blockers"].join(" "),
        "refusing to overwrite",
        plan["repositories"].first.inspect
      )

      stopped = store.install_all(failure_policy: "stop")
      assert_equal false, stopped["ok"]
      assert_equal "blocked", stopped["repositories"][0].dig("bridge", "status")
      assert_equal "not_attempted", stopped["repositories"][1].dig("bridge", "status")

      receipt = store.install_all(failure_policy: "continue")
      assert_equal false, receipt["ok"]
      assert_equal "blocked", receipt["repositories"][0].dig("bridge", "status")
      assert_equal "installed", receipt["repositories"][1].dig("bridge", "status")
      assert_equal "unmanaged instructions\n", File.read(File.join(conflict, "AGENTS.override.md"))
    end
  end

  def test_bulk_bridge_project_registration_requires_exact_verified_path
    with_hub do |root, config|
      verified = initialize_repository(root, "project-verified")
      pending = initialize_repository(root, "project-pending")
      [verified, pending].each { |path| commit_repository(path) }
      config = register_repository(config, "project-verified", verified)
      config = register_repository(config, "project-pending", pending)
      config = write_declarations(
        config,
        [declaration("project-verified", verified), declaration("project-pending", pending)]
      )
      Kepler::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "project-verified" => {
              "logical_key" => "project-verified",
              "runtime_project_id" => "opaque-runtime-project-verified",
              "path" => verified,
              "verified" => true,
              "verification_source" => "live_project_list_exact_path",
              "verified_at" => "2026-01-01T00:00:00Z"
            }
          }
        }
      )

      plan = Kepler::BridgeBulkStore.new(Kepler::Config.new(root: root)).plan
      states = plan["repositories"].to_h do |item|
        [item["repository_id"], item.dig("project_registration", "status")]
      end
      assert_equal "verified", states["project-verified"]
      assert_equal "pending", states["project-pending"]
      verified_item = plan["repositories"].find { |item| item["repository_id"] == "project-verified" }
      assert_equal "project-verified", verified_item.dig("project_registration", "logical_key")
      assert_equal "opaque-runtime-project-verified",
                   verified_item.dig("project_registration", "runtime_project_id")
      refute_equal verified_item.dig("project_registration", "logical_key"),
                   verified_item.dig("project_registration", "runtime_project_id")
      Kepler::BridgeStore.new(Kepler::Config.new(root: root)).install(
        repository_id: "project-verified",
        mode: "reference",
        profile: "application"
      )
      route = Kepler::RoutePlanner.new(Kepler::Config.new(root: root)).plan(
        workload_name: "development",
        work_type: "implementation",
        repository_id: "project-verified"
      )
      assert_equal "project-verified", route["project_key"]
      assert_equal "opaque-runtime-project-verified", route["runtime_project_id"]
      assert route["dispatch_ready"]

      project_state = Kepler::Support.load_data(config.project_registry_path)
      project_state["projects"]["project-pending"] = {
        "logical_key" => "project-pending",
        "runtime_project_id" => "opaque-runtime-project-pending",
        "path" => verified,
        "verified" => true,
        "verification_source" => "live_project_list_exact_path",
        "verified_at" => "2026-01-01T00:00:00Z"
      }
      Kepler::Support.atomic_yaml(config.project_registry_path, project_state)
      conflict_config = Kepler::Config.new(root: root)
      conflict = Kepler::BridgeBulkStore.new(conflict_config).plan
      pending_item = conflict["repositories"].find { |item| item["repository_id"] == "project-pending" }
      assert_equal "conflict", pending_item.dig("project_registration", "status")
      doctor = Kepler::Doctor.new(conflict_config).run
      assert_includes doctor["issues"].map { |item| item["code"] }, "project.registration_conflict"

      route = Kepler::RoutePlanner.new(Kepler::Config.new(root: root)).plan(
        workload_name: "development",
        work_type: "implementation",
        repository_id: "project-verified"
      )
      assert_equal "project-verified", route["project_key"]
      assert_equal "opaque-runtime-project-verified", route["runtime_project_id"]
      assert route["dispatch_ready"]
      assert_equal "reference", route.dig("bridge_handoff", "mode")
    end
  end

  def test_legacy_logical_key_runtime_id_self_equality_record_is_rejected
    with_hub do |root, config|
      repository = initialize_repository(root, "legacy-self-equality")
      commit_repository(repository)
      config = register_repository(config, "legacy-self-equality", repository)
      write_declarations(config, [declaration("legacy-self-equality", repository)])
      Kepler::Support.atomic_yaml(
        config.project_registry_path,
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {
            "legacy-self-equality" => {
              "project_id" => "legacy-self-equality",
              "path" => repository,
              "verified" => true
            }
          }
        }
      )

      error = assert_raises(Kepler::ConfigurationError) do
        Kepler::Config.new(root: root).project_verifications
      end
      assert_includes error.message, "runtime_project_id"
    end
  end

  def test_repository_declarations_refuse_credentials_and_absolute_paths
    with_hub do |root, config|
      repository = initialize_repository(root, "declaration-safety")
      commit_repository(repository)
      unsafe = declaration("declaration-safety", repository)
      unsafe["provider"] = "git"
      unsafe["locator"] = "https://user:secret@example.invalid/repository.git"
      config = write_declarations(config, [unsafe])
      assert_raises(Kepler::ConfigurationError) { config.repository_declarations }

      unsafe["locator"] = "https://example.invalid/repository.git"
      unsafe["local_path"] = repository
      config = write_declarations(config, [unsafe])
      assert_raises(Kepler::ConfigurationError) { config.repository_declarations }
    end
  end

  def test_plan_context_dispatch_result_and_dependency_progression
    with_hub do |root, config|
      product_path = File.join(root, "development", "product-monorepo")
      FileUtils.mkdir_p(product_path)
      registry = Kepler::Support.load_data(File.join(root, "kepler.yaml"))
      registry["codex_projects"]["product-monorepo"] = {
        "display_name" => "Product Monorepo",
        "context" => "local",
        "path" => product_path,
        "role" => "implementation",
        "required" => true
      }
      Kepler::Support.atomic_yaml(File.join(root, "kepler.yaml"), registry)
      Kepler::Support.atomic_yaml(config.project_registry_path, {
        "api_version" => "kepler.dev/v1alpha1",
        "kind" => "CodexProjectVerifications",
        "projects" => {
          "product-monorepo" => {
            "logical_key" => "product-monorepo",
            "runtime_project_id" => "runtime-product-1",
            "path" => product_path,
            "verified" => true,
            "verification_source" => "live_project_list_exact_path",
            "verified_at" => "2026-08-23T00:00:00Z"
          }
        }
      })
      config = Kepler::Config.new(root: root)
      architecture_source = File.join(root, "architecture-source.yaml")
      Kepler::Support.atomic_yaml(architecture_source, {
        "api_version" => "kepler.dev/v1",
        "kind" => "ArchitectureMap",
        "workspaces" => {
          "product" => {
            "codex_project" => "product-monorepo",
            "repository" => "product-monorepo",
            "domains" => {
              "backend" => { "paths" => ["apps/api"], "facts" => ["PostgreSQL owns persistence"] },
              "frontend" => { "paths" => ["apps/web"] }
            }
          }
        },
        "relationships" => { "product.frontend" => { "depends_on" => ["product.backend"] } }
      })
      Kepler::ArchitectureMapStore.new(config).confirm(architecture_source)

      memory_source = File.join(root, "memory-source.yaml")
      Kepler::Support.atomic_yaml(memory_source, {
        "api_version" => "kepler.dev/v1",
        "kind" => "MemoryItem",
        "metadata" => { "id" => "attempt-middleware", "created_at" => "2026-08-23T00:00:00Z" },
        "scope" => "DOMAIN",
        "type" => "ATTEMPT",
        "workspace" => "product",
        "domain" => "product.backend",
        "statement" => "Request middleware caused duplicate audit records.",
        "source" => "worker-result:prior"
      })
      Kepler::MemoryStore.new(config).ingest(memory_source)

      plan_source = File.join(root, "plan-source.yaml")
      Kepler::Support.atomic_yaml(plan_source, {
        "api_version" => "kepler.dev/v1",
        "kind" => "Plan",
        "metadata" => { "id" => "kepler-021", "revision" => 1 },
        "objective" => "Add administrator audit logging and expose events in the UI.",
        "constraints" => ["reuse the existing audit_events table"],
        "status" => { "state" => "draft" },
        "units" => [
          { "id" => "backend", "workspace" => "product", "domain" => "backend", "paths" => ["apps/api"], "dependencies" => [], "status" => "planned", "success_criteria" => ["backend tests pass"] },
          { "id" => "frontend", "workspace" => "product", "domain" => "frontend", "paths" => ["apps/web"], "dependencies" => ["backend"], "status" => "planned" }
        ]
      })
      store = Kepler::PlanStore.new(config)
      created = store.apply(plan_source)
      assert_equal ["backend"], created["ready_units"]
      assert_equal ["Initial Plan"], store.load("kepler-021").dig("metadata", "change_summary")
      assert_raises(Kepler::ValidationError) { store.prepare_dispatch(id: "kepler-021", revision: 2) }

      dispatch = store.prepare_dispatch(id: "kepler-021", revision: 1)
      assert_equal ["backend"], dispatch["units"].map { |unit| unit["unit_id"] }
      pack = Kepler::Support.load_data(File.join(root, dispatch["units"][0]["context_pack_path"]))
      assert pack.dig("worker_policy", "initial_context_not_boundary")
      assert_includes pack["prior_attempts"], "Request middleware caused duplicate audit records."
      assert_operator pack.dig("metadata", "estimated_tokens"), :<=, pack.dig("metadata", "token_budget")

      second_plan_source = File.join(root, "second-plan-source.yaml")
      second_plan = Kepler::Support.load_data(plan_source)
      second_plan["metadata"]["id"] = "kepler-022"
      Kepler::Support.atomic_yaml(second_plan_source, second_plan)
      store.apply(second_plan_source)
      second_dispatch = store.prepare_dispatch(id: "kepler-022", revision: 1, unit_id: "backend")
      refute_equal dispatch["units"][0]["context_pack_path"],
                   second_dispatch["units"][0]["context_pack_path"]

      receipt_source = File.join(root, "receipt.yaml")
      Kepler::Support.atomic_yaml(receipt_source, {
        "api_version" => "kepler.dev/v1",
        "kind" => "DispatchReceipt",
        "task_id" => "task-backend-1",
        "runtime_project_id" => "runtime-product-1",
        "project_path" => product_path,
        "mode" => "worktree",
        "authorization_boundary" => "implementation only"
      })
      store.record_dispatch(id: "kepler-021", revision: 1, unit_id: "backend", receipt_path: receipt_source)
      dispatched = store.summary(store.load("kepler-021"))
      backend_status = dispatched["unit_status"].find { |item| item["id"] == "backend" }
      assert_equal "task-backend-1", backend_status.dig("worker", "task_id")

      revised_plan = store.load("kepler-021")
      revised_plan["metadata"]["revision"] = 2
      revised_plan["constraints"] << "retain the public API contract"
      revised_backend = revised_plan["units"].find { |unit| unit["id"] == "backend" }
      revised_backend["status"] = "planned"
      revised_backend.delete("dispatch_receipt")
      Kepler::Support.atomic_yaml(plan_source, revised_plan)
      revised = store.apply(plan_source, expected_revision: 1)
      assert_equal 2, revised["revision"]
      carried_backend = store.load("kepler-021")["units"].find { |unit| unit["id"] == "backend" }
      assert_equal "dispatched", carried_backend.dig("status", "state")
      assert carried_backend["dispatch_receipt"]
      assert_includes store.load("kepler-021").dig("metadata", "change_summary"), "Constraints changed"

      result_source = File.join(root, "result.yaml")
      Kepler::Support.atomic_yaml(result_source, {
        "api_version" => "kepler.dev/v1",
        "kind" => "WorkerResult",
        "metadata" => { "id" => "result-backend-blocked", "plan_id" => "kepler-021", "plan_revision" => 1, "unit_id" => "backend" },
        "status" => "blocked",
        "summary" => "The audit persistence choice needs a Plan decision.",
        "blockers" => ["Choose the durable event identifier."],
        "handoffs" => { "frontend" => ["API contract unchanged"] },
        "validation" => []
      })
      blocked = store.ingest_result(result_source)
      assert_equal "blocked", blocked["state"]
      assert_equal "blocked", blocked["unit_status"].find { |item| item["id"] == "backend" }["state"]

      retry_plan = store.load("kepler-021")
      retry_plan["metadata"]["revision"] = 3
      retry_plan["units"].find { |unit| unit["id"] == "backend" }["retry"] = true
      Kepler::Support.atomic_yaml(plan_source, retry_plan)
      retried = store.apply(plan_source, expected_revision: 2)
      assert_equal ["backend"], retried["ready_units"]
      assert_equal "ready", retried["state"]
      plan_schema = Kepler::Support.load_data(File.join(root, "hub", "schemas", "plan.schema.json"))
      assert_equal "boolean", plan_schema.dig("properties", "units", "items", "properties", "retry", "type")
      assert_includes store.load("kepler-021").dig("metadata", "change_summary"), "Retried unit backend"
      refute store.load("kepler-021")["units"].find { |unit| unit["id"] == "backend" }.key?("retry")

      store.prepare_dispatch(id: "kepler-021", revision: 3, unit_id: "backend")
      store.record_dispatch(id: "kepler-021", revision: 3, unit_id: "backend", receipt_path: receipt_source)
      Kepler::Support.atomic_yaml(result_source, {
        "api_version" => "kepler.dev/v1",
        "kind" => "WorkerResult",
        "metadata" => { "id" => "result-backend-1", "plan_id" => "kepler-021", "plan_revision" => 3, "unit_id" => "backend" },
        "status" => "completed",
        "summary" => "Added audit persistence.",
        "changes" => ["apps/api/audit.rb"],
        "handoffs" => { "frontend" => ["API contract unchanged"] },
        "validation" => [{ "name" => "backend tests", "status" => "passed" }]
      })
      completed = store.ingest_result(result_source)
      assert_equal ["frontend"], completed["ready_units"]
      backend_status = completed["unit_status"].find { |item| item["id"] == "backend" }
      assert_equal "passed", backend_status.dig("validation", 0, "status")

      frontend_dispatch = store.prepare_dispatch(id: "kepler-021", revision: 3, unit_id: "frontend")
      frontend_pack = Kepler::Support.load_data(File.join(root, frontend_dispatch["units"][0]["context_pack_path"]))
      assert_equal 3, frontend_pack.dig("parent_plan", "revision")
      assert_equal ["API contract unchanged"], frontend_pack.dig("upstream_handoffs", 0, "items")
      assert_equal 1, frontend_pack.dig("telemetry", "upstream_handoff_count")
      assert_operator frontend_pack.dig("telemetry", "memory", "estimated_tokens"), :<=,
                      frontend_pack.dig("telemetry", "memory", "token_budget")
    end
  end

  def test_memory_deduplication_supersession_and_budget_telemetry
    with_hub do |root, config|
      store = Kepler::MemoryStore.new(config)
      malformed = File.join(root, "malformed-memory.yaml")
      [
        { "id" => "workspace-without-workspace", "scope" => "WORKSPACE" },
        { "id" => "domain-without-domain", "scope" => "DOMAIN", "workspace" => "product" },
        { "id" => "work-without-workspace", "scope" => "WORK", "domain" => "product.backend" }
      ].each do |declaration|
        Kepler::Support.atomic_yaml(malformed, {
          "api_version" => "kepler.dev/v1", "kind" => "MemoryItem",
          "metadata" => { "id" => declaration["id"] }, "scope" => declaration["scope"],
          "type" => "FACT", "statement" => "This item is incompletely scoped.",
          "source" => "test"
        }.merge(declaration.reject { |key, _value| key == "id" || key == "scope" }))
        assert_raises(Kepler::ValidationError) { store.ingest(malformed) }
      end

      first = File.join(root, "first-memory.yaml")
      Kepler::Support.atomic_yaml(first, {
        "api_version" => "kepler.dev/v1", "kind" => "MemoryItem",
        "metadata" => { "id" => "old-fact" }, "scope" => "SYSTEM", "type" => "FACT",
        "statement" => "Use the stable API.", "source" => "test"
      })
      assert_equal "stored", store.ingest(first)["status"]

      duplicate = File.join(root, "duplicate-memory.yaml")
      Kepler::Support.atomic_yaml(duplicate, {
        "api_version" => "kepler.dev/v1", "kind" => "MemoryItem",
        "metadata" => { "id" => "duplicate-fact" }, "scope" => "SYSTEM", "type" => "FACT",
        "statement" => "Use the stable API.", "source" => "second test"
      })
      assert_equal "duplicate", store.ingest(duplicate)["status"]

      replacement = File.join(root, "replacement-memory.yaml")
      Kepler::Support.atomic_yaml(replacement, {
        "api_version" => "kepler.dev/v1", "kind" => "MemoryItem",
        "metadata" => { "id" => "new-fact" }, "scope" => "SYSTEM", "type" => "FACT",
        "statement" => "Use the versioned API.", "source" => "decision", "supersedes" => "old-fact"
      })
      assert_equal ["old-fact"], store.ingest(replacement)["superseded"]
      query = store.query(text: "API", token_budget: 300)
      assert_equal ["new-fact"], query["items"].map { |item| item.dig("metadata", "id") }
      assert_equal 1, query.dig("telemetry", "rejected", "invalidated")
      assert_operator query.dig("telemetry", "estimated_tokens"), :<=, 300
    end
  end

  def test_plan_rejects_cycles_and_non_monotonic_revisions
    with_hub do |root, config|
      source = File.join(root, "cycle.yaml")
      Kepler::Support.atomic_yaml(source, {
        "api_version" => "kepler.dev/v1", "kind" => "Plan",
        "metadata" => { "id" => "cycle", "revision" => 1 },
        "objective" => "Synthetic cycle", "status" => { "state" => "draft" },
        "units" => [
          { "id" => "a", "workspace" => "w", "domain" => "a", "paths" => ["a"], "dependencies" => ["b"] },
          { "id" => "b", "workspace" => "w", "domain" => "b", "paths" => ["b"], "dependencies" => ["a"] }
        ]
      })
      assert_raises(Kepler::ValidationError) do
        Kepler::Contracts.plan!(Kepler::Support.load_data(source))
      end
    end
  end

  def test_architecture_map_rejects_unknown_relationship_targets
    with_hub do |root, config|
      source = File.join(root, "architecture-invalid.yaml")
      Kepler::Support.atomic_yaml(source, {
        "api_version" => "kepler.dev/v1", "kind" => "ArchitectureMap",
        "workspaces" => {
          "product" => {
            "codex_project" => "product", "repository" => "product",
            "domains" => { "backend" => { "paths" => ["apps/api"] } }
          }
        },
        "relationships" => { "product.backend" => { "depends_on" => ["platform.helm"] } }
      })
      error = assert_raises(Kepler::ValidationError) do
        Kepler::ArchitectureMapStore.new(config).confirm(source)
      end
      assert_includes error.message, "relationship target is unknown"
    end
  end
end

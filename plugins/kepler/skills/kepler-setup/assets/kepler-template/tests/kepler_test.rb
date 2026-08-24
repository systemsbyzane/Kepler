# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "yaml"

require "kepler/cli"
require "kepler/config"
require "kepler/contracts"
require "kepler/doctor"
require "kepler/plan_store"
require "kepler/route_planner"
require "kepler/setup_store"

class KeplerTest < Minitest::Test
  TEMPLATE_ROOT = File.expand_path("..", __dir__)
  REMOVED_WORKLOAD_ROOTS = %w[development charts patching research environments compliance].freeze

  def with_control
    Dir.mktmpdir("kepler-control-test-") do |directory|
      root = File.join(directory, "Kepler-Synthetic")
      FileUtils.mkdir_p(root)
      Dir.children(TEMPLATE_ROOT).each do |entry|
        FileUtils.cp_r(File.join(TEMPLATE_ROOT, entry), File.join(root, entry))
      end
      File.write(
        File.join(root, "kepler.yaml"),
        File.read(File.join(root, "kepler.yaml")).gsub("__KEPLER_ROOT__", root)
      )
      FileUtils.mkdir_p(File.join(root, "hub", "state"))
      Kepler::Support.atomic_yaml(
        File.join(root, "hub", "state", "repositories.yaml"),
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "LocalRepositoryRegistry",
          "repositories" => {}
        }
      )
      Kepler::Support.atomic_yaml(
        File.join(root, "hub", "state", "projects.yaml"),
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "CodexProjectVerifications",
          "projects" => {}
        }
      )
      yield root, Kepler::Config.new(root: root), directory
    end
  end

  def create_catalog(directory)
    alpha = File.join(directory, "alpha-project")
    beta = File.join(directory, "beta-project")
    FileUtils.mkdir_p(alpha)
    FileUtils.mkdir_p(beta)
    catalog = File.join(directory, "projects.json")
    File.write(
      catalog,
      JSON.pretty_generate(
        {
          "schemaVersion" => 2,
          "projects" => [
            {
              "projectId" => "runtime-alpha-001",
              "projectKind" => "local",
              "label" => "Alpha",
              "path" => alpha,
              "hostId" => "local",
              "isGitRepository" => true
            },
            {
              "projectId" => "runtime-beta-002",
              "projectKind" => "local",
              "label" => "Beta",
              "path" => beta,
              "hostId" => "local",
              "isGitRepository" => false
            }
          ]
        }
      )
    )
    [catalog, alpha, beta]
  end

  def configured_control
    with_control do |root, config, directory|
      catalog, alpha, beta = create_catalog(directory)
      result = Kepler::SetupStore.new(config).apply(
        project_catalog: catalog,
        project_ids: %w[runtime-alpha-001 runtime-beta-002],
        confirm: true
      )
      yield root, Kepler::Config.new(root: root), directory, result, alpha, beta
    end
  end

  def plan_document(revision: 1)
    {
      "api_version" => "kepler.dev/v1",
      "kind" => "Plan",
      "metadata" => { "id" => "synthetic-plan", "revision" => revision },
      "objective" => "Change the selected project safely.",
      "constraints" => ["Do not publish."],
      "units" => [
        {
          "id" => "alpha-change",
          "workspace" => "alpha",
          "domain" => "root",
          "paths" => ["."],
          "dependencies" => [],
          "success_criteria" => ["Focused validation passes."],
          "status" => { "state" => "planned" }
        }
      ],
      "status" => { "state" => "draft" }
    }
  end

  def test_template_has_no_workload_topology
    config = Kepler::Config.new(root: TEMPLATE_ROOT)
    assert_equal({}, config.workloads)
    assert_equal(["kepler"], config.codex_projects.keys)
    REMOVED_WORKLOAD_ROOTS.each do |name|
      refute File.exist?(File.join(TEMPLATE_ROOT, name)), "unexpected workload root: #{name}"
    end
  end

  def test_setup_plan_selects_live_projects_without_mutation
    with_control do |root, config, directory|
      catalog, alpha, beta = create_catalog(directory)
      before = [Dir.children(alpha), Dir.children(beta), File.read(config.project_registry_path)]
      result = Kepler::SetupStore.new(config).plan(
        project_catalog: catalog,
        project_ids: %w[runtime-alpha-001 runtime-beta-002]
      )
      assert result["read_only"]
      assert_equal 2, result.dig("summary", "selected")
      assert_equal false, result["repository_scan_performed"]
      assert_equal 0, result.dig("bridges", "installed")
      assert_equal false, result.dig("architecture_map", "metadata", "confirmed")
      assert_equal before, [Dir.children(alpha), Dir.children(beta), File.read(config.project_registry_path)]
      refute File.exist?(File.join(root, "hub", "architecture-map.yaml"))
    end
  end

  def test_setup_apply_requires_confirmation
    with_control do |_root, config, directory|
      catalog, = create_catalog(directory)
      assert_raises(Kepler::UsageError) do
        Kepler::SetupStore.new(config).apply(
          project_catalog: catalog,
          project_ids: ["runtime-alpha-001"]
        )
      end
    end
  end

  def test_setup_apply_accepts_user_refined_architecture_file
    with_control do |_root, config, directory|
      catalog, = create_catalog(directory)
      store = Kepler::SetupStore.new(config)
      preview = store.plan(
        project_catalog: catalog,
        project_ids: %w[runtime-alpha-001 runtime-beta-002]
      )
      refined = preview.fetch("architecture_map")
      refined.fetch("workspaces").fetch("alpha").fetch("domains")["api"] = {
        "paths" => ["lib"],
        "facts" => ["User-confirmed API domain."]
      }
      source = File.join(directory, "refined-architecture.yaml")
      Kepler::Support.atomic_yaml(source, refined)

      result = store.apply(
        project_catalog: catalog,
        project_ids: %w[runtime-alpha-001 runtime-beta-002],
        architecture_map: source,
        confirm: true
      )
      assert_equal true, result.dig("architecture_map", "metadata", "confirmed")
      assert_equal "explicit_setup_apply_confirmed_file", result.dig("architecture_map", "metadata", "confirmation_source")
      assert result.dig("architecture_map", "workspaces", "alpha", "domains").key?("api")
    end
  end

  def test_setup_apply_persists_exact_identity_and_confirmed_architecture
    configured_control do |_root, config, _directory, result, alpha, beta|
      assert_equal "configured", result["status"]
      assert_equal true, result.dig("architecture_map", "metadata", "confirmed")
      projects = config.project_verifications
      assert_equal %w[alpha beta], projects.keys.sort
      assert_equal File.realpath(alpha), projects.dig("alpha", "path")
      assert_equal "runtime-alpha-001", projects.dig("alpha", "runtime_project_id")
      assert_equal File.realpath(beta), projects.dig("beta", "path")
      assert_equal [], Dir.children(alpha)
      assert_equal [], Dir.children(beta)
    end
  end

  def test_setup_apply_is_idempotent_and_preserves_refined_architecture
    with_control do |_root, config, directory|
      catalog, = create_catalog(directory)
      store = Kepler::SetupStore.new(config)
      first = store.apply(
        project_catalog: catalog,
        project_ids: %w[runtime-alpha-001 runtime-beta-002],
        confirm: true
      )
      assert_equal true, first["changed"]

      architecture = Kepler::Support.load_data(config.architecture_map_path)
      architecture.fetch("workspaces").fetch("alpha").fetch("domains")["api"] = {
        "paths" => ["lib"],
        "facts" => ["User-confirmed API domain."]
      }
      Kepler::Support.atomic_yaml(config.architecture_map_path, architecture)
      registry_before = File.read(config.project_registry_path)
      architecture_before = File.read(config.architecture_map_path)

      second = Kepler::SetupStore.new(Kepler::Config.new(root: config.root)).apply(
        project_catalog: catalog,
        project_ids: %w[runtime-alpha-001 runtime-beta-002],
        confirm: true
      )
      assert_equal false, second["changed"]
      assert_equal registry_before, File.read(config.project_registry_path)
      assert_equal architecture_before, File.read(config.architecture_map_path)
      assert second.dig("architecture_map", "workspaces", "alpha", "domains").key?("api")
    end
  end

  def test_setup_rejects_unknown_project_id
    with_control do |_root, config, directory|
      catalog, = create_catalog(directory)
      error = assert_raises(Kepler::ValidationError) do
        Kepler::SetupStore.new(config).plan(
          project_catalog: catalog,
          project_ids: ["missing"]
        )
      end
      assert_includes error.message, "absent from the live catalog"
    end
  end

  def test_setup_rejects_the_control_project_itself
    with_control do |root, config, directory|
      catalog = File.join(directory, "self-project.json")
      File.write(
        catalog,
        JSON.pretty_generate(
          {
            "schemaVersion" => 2,
            "projects" => [
              {
                "projectId" => "runtime-control-001",
                "label" => "Kepler Synthetic",
                "path" => root,
                "isGitRepository" => false
              }
            ]
          }
        )
      )
      error = assert_raises(Kepler::ValidationError) do
        Kepler::SetupStore.new(config).plan(
          project_catalog: catalog,
          project_ids: ["runtime-control-001"]
        )
      end
      assert_includes error.message, "cannot select itself"
    end
  end

  def test_architecture_map_requires_explicit_confirmation
    value = {
      "api_version" => "kepler.dev/v1",
      "kind" => "ArchitectureMap",
      "metadata" => { "confirmed" => false },
      "workspaces" => {},
      "relationships" => {}
    }
    assert_includes(
      assert_raises(Kepler::ValidationError) { Kepler::Contracts.architecture_map!(value) }.message,
      "explicit confirmation"
    )
  end

  def test_route_uses_terra_and_bridge_is_optional
    configured_control do |_root, config, _directory, _result, alpha, _beta|
      route = Kepler::RoutePlanner.new(config).plan(
        workspace: "alpha",
        domain: "root",
        work_type: "implementation"
      )
      assert_equal File.realpath(alpha), route["project_path"]
      assert_equal "runtime-alpha-001", route["runtime_project_id"]
      assert_equal "gpt-5.6-sol", route.dig("planner_runtime", "requested_model")
      assert_equal "gpt-5.6-terra", route.dig("dispatcher_runtime", "requested_model")
      assert_equal "not_configured", route.dig("bridge_handoff", "status")
      assert_equal false, route.dig("context_policy", "context_pack_is_exclusive_boundary")
      assert_equal false, route.dig("context_policy", "transcript_sync")
      assert route["stop_after_dispatch"]
    end
  end

  def test_opted_in_bridge_fails_closed_when_missing_or_drifting
    configured_control do |_root, config, _directory, _result, alpha, _beta|
      assert system("git", "init", "-q", alpha)
      Kepler::Support.atomic_yaml(
        config.local_registry_path,
        {
          "api_version" => "kepler.dev/v1alpha1",
          "kind" => "LocalRepositoryRegistry",
          "repositories" => {
            "alpha-bridge" => {
              "local_path" => alpha,
              "placement" => "attached",
              "bridge_mode" => "reference",
              "bridge_profile" => "application"
            }
          }
        }
      )
      architecture = Kepler::Support.load_data(config.architecture_map_path)
      architecture.fetch("workspaces").fetch("alpha")["bridge_repository_id"] = "alpha-bridge"
      Kepler::Support.atomic_yaml(config.architecture_map_path, architecture)

      missing = assert_raises(Kepler::ValidationError) do
        Kepler::RoutePlanner.new(Kepler::Config.new(root: config.root)).plan(
          workspace: "alpha", domain: "root", work_type: "implementation"
        )
      end
      assert_includes missing.message, "bridge is not installed"

      store = Kepler::BridgeStore.new(Kepler::Config.new(root: config.root))
      record = store.install(repository_id: "alpha-bridge", mode: "reference", profile: "application")
      assert_equal true, record["verified"]
      route = Kepler::RoutePlanner.new(Kepler::Config.new(root: config.root)).plan(
        workspace: "alpha", domain: "root", work_type: "implementation"
      )
      assert_equal "verified", route.dig("bridge_handoff", "status")

      File.open(File.join(alpha, "AGENTS.override.md"), "a") { |file| file.write("\ndrift\n") }
      drifting = assert_raises(Kepler::ValidationError) do
        Kepler::RoutePlanner.new(Kepler::Config.new(root: config.root)).plan(
          workspace: "alpha", domain: "root", work_type: "implementation"
        )
      end
      assert_includes drifting.message, "configured bridge must be valid"
    end
  end

  def test_plan_revisions_and_stale_dispatch_fail_closed
    configured_control do |root, config, _directory, _result, _alpha, _beta|
      source = File.join(root, "plan.yaml")
      Kepler::Support.atomic_yaml(source, plan_document)
      store = Kepler::PlanStore.new(config)
      created = store.apply(source)
      assert_equal 1, created["revision"]
      error = assert_raises(Kepler::ValidationError) do
        store.prepare_dispatch(id: "synthetic-plan", revision: 2)
      end
      assert_includes error.message, "stale Plan revision"

      revised_document = plan_document(revision: 2)
      revised_document["objective"] = "Change the selected project with the refined constraint."
      Kepler::Support.atomic_yaml(source, revised_document)
      revised = store.apply(source, expected_revision: 1)
      assert_equal 2, revised["revision"]
      assert_includes revised["change_summary"], "Objective changed"
    end
  end

  def test_dispatch_context_and_structured_result_progression
    configured_control do |root, config, _directory, _result, alpha, _beta|
      source = File.join(root, "plan.yaml")
      Kepler::Support.atomic_yaml(source, plan_document)
      store = Kepler::PlanStore.new(config)
      store.apply(source)
      envelope = store.prepare_dispatch(id: "synthetic-plan", revision: 1).fetch("units").first
      assert_equal "runtime-alpha-001", envelope["runtime_project_id"]
      assert envelope["receipt_and_stop"]
      context = Kepler::Support.load_data(File.join(root, envelope["context_pack_path"]))
      assert_equal true, context.dig("worker_policy", "initial_context_not_boundary")
      assert_equal File.realpath(alpha), context.dig("scope", "project_path")

      receipt = File.join(root, "receipt.yaml")
      Kepler::Support.atomic_yaml(
        receipt,
        {
          "api_version" => "kepler.dev/v1",
          "kind" => "DispatchReceipt",
          "task_id" => "task-alpha-001",
          "runtime_project_id" => "runtime-alpha-001",
          "project_path" => alpha,
          "mode" => "worktree",
          "requested_model" => "gpt-5.6-terra",
          "effective_model" => "gpt-5.6-terra",
          "requested_thinking" => "high",
          "effective_thinking" => "high",
          "authorization_boundary" => "No remote writes."
        }
      )
      store.record_dispatch(
        id: "synthetic-plan",
        revision: 1,
        unit_id: "alpha-change",
        receipt_path: receipt
      )
      worker_result = File.join(root, "worker-result.yaml")
      Kepler::Support.atomic_yaml(
        worker_result,
        {
          "api_version" => "kepler.dev/v1",
          "kind" => "WorkerResult",
          "metadata" => {
            "id" => "result-alpha-001",
            "plan_id" => "synthetic-plan",
            "plan_revision" => 1,
            "unit_id" => "alpha-change"
          },
          "status" => "completed",
          "summary" => "Synthetic work completed.",
          "validation" => ["Focused test passed."],
          "changes" => [],
          "discoveries" => [],
          "decisions" => [],
          "failed_attempts" => [],
          "inferences" => [],
          "blockers" => [],
          "artifacts" => [],
          "memory_candidates" => []
        }
      )
      summary = store.ingest_result(worker_result)
      assert_equal "completed", summary["state"]
    end
  end

  def test_cli_help_exposes_explicit_primary_commands
    output = StringIO.new
    status = Kepler::CLI.new(root: TEMPLATE_ROOT, out: output, err: StringIO.new).run(["help"])
    assert_equal 0, status
    %w[setup plan dispatch status review doctor].each do |command|
      assert_includes output.string, "bin/kepler #{command}"
    end
  end

  def test_doctor_accepts_configured_project_first_control
    configured_control do |_root, config, _directory, _result, _alpha, _beta|
      doctor = Kepler::Doctor.new(config).run
      assert_equal 0, doctor.dig("summary", "errors"), doctor["issues"].inspect
      assert_equal 0, doctor.dig("summary", "repositories")
      assert_equal 0, doctor.dig("summary", "bridges")
      assert_equal true, doctor.dig("coordination", "architecture_map")
    end
  end
end

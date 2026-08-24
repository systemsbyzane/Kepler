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

  def herdr_attachment(task_id:, worker_cwd:)
    {
      "schema_version" => "kepler.herdr-attachment/v1",
      "herdr_version" => "0.8.0",
      "protocol" => 19,
      "workspace_id" => "workspace-alpha-change",
      "tab_id" => "tab-alpha-change",
      "pane_id" => "pane-alpha-change",
      "agent_name" => "alpha-change",
      "agent_kind" => "codex",
      "resumed_task_id" => task_id,
      "worker_cwd" => worker_cwd,
      "workspace_owned" => true,
      "tab_owned" => true,
      "pane_owned" => true,
      "agent_owned" => true
    }
  end

  def test_template_has_no_workload_topology
    config = Kepler::Config.new(root: TEMPLATE_ROOT)
    assert_equal({}, config.workloads)
    assert_equal(["kepler"], config.codex_projects.keys)
    assert_equal File.join(TEMPLATE_ROOT, "hub", "cleanup-receipts"), config.cleanup_receipt_dir
    assert Dir.exist?(config.cleanup_receipt_dir)
    REMOVED_WORKLOAD_ROOTS.each do |name|
      refute File.exist?(File.join(TEMPLATE_ROOT, name)), "unexpected workload root: #{name}"
    end
  end

  def test_setup_plan_selects_live_projects_without_mutation
    with_control do |root, config, directory|
      catalog, alpha, beta = create_catalog(directory)
      architecture_map_path = File.join(root, "hub", "architecture-map.yaml")
      architecture_map_before =
        File.exist?(architecture_map_path) ? File.binread(architecture_map_path) : nil
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
      architecture_map_after =
        File.exist?(architecture_map_path) ? File.binread(architecture_map_path) : nil
      if architecture_map_before.nil?
        assert_nil architecture_map_after
      else
        assert_equal architecture_map_before, architecture_map_after
      end
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

  def test_route_keeps_dispatch_in_control_task_and_uses_terra_workers
    configured_control do |_root, config, _directory, _result, alpha, _beta|
      route = Kepler::RoutePlanner.new(config).plan(
        workspace: "alpha",
        domain: "root",
        work_type: "implementation"
      )
      assert_equal File.realpath(alpha), route["project_path"]
      assert_equal "runtime-alpha-001", route["runtime_project_id"]
      assert_equal "gpt-5.6-sol", route.dig("planner_runtime", "requested_model")
      assert_equal "current_control_task", route.dig("dispatch_execution", "owner")
      assert_equal false, route.dig("dispatch_execution", "intermediary_dispatch_task_permitted")
      assert_equal "codex-thread-message", route.dig("dispatch_execution", "prompt_delivery_method")
      assert_equal "app-server-and-live-project-task-list-before-and-after", route.dig("dispatch_execution", "project_association_verification")
      assert_equal "gpt-5.6-terra", route.dig("worker_runtime", "requested_model")
      assert_equal "not_configured", route.dig("bridge_handoff", "status")
      assert_equal false, route.dig("context_policy", "context_pack_is_exclusive_boundary")
      assert_equal true, route.dig("context_policy", "context_pack_serialized_once")
      assert_equal 2_000, route.dig("context_policy", "worker_result_token_budget")
      assert_equal "unavailable", route.dig("context_policy", "runtime_token_usage")
      assert_equal false, route.dig("context_policy", "transcript_sync")
      assert_includes route.dig("dispatch_receipt", "fields"), "context_pack_estimated_tokens"
      assert_includes route.dig("dispatch_receipt", "fields"), "dispatch_execution"
      assert_includes route.dig("dispatch_receipt", "fields"), "project_association_after"
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
    configured_control do |root, config, directory, _result, alpha, _beta|
      source = File.join(root, "plan.yaml")
      Kepler::Support.atomic_yaml(source, plan_document)
      store = Kepler::PlanStore.new(config)
      store.apply(source)
      envelope = store.prepare_dispatch(id: "synthetic-plan", revision: 1).fetch("units").first
      assert_equal "runtime-alpha-001", envelope["runtime_project_id"]
      assert envelope["receipt_and_stop"]
      context = Kepler::Support.load_data(File.join(root, envelope["context_pack_path"]))
      assert_equal true, context.dig("worker_policy", "initial_context_not_boundary")
      assert_equal true, context.dig("worker_policy", "structured_result_only")
      assert_equal true, context.dig("worker_policy", "avoid_context_repetition")
      assert_equal 2_000, context.dig("worker_policy", "result_token_budget")
      assert_equal File.realpath(alpha), context.dig("scope", "project_path")

      assert system("git", "-C", alpha, "init", "-q")
      assert system("git", "-C", alpha, "config", "user.email", "kepler@example.test")
      assert system("git", "-C", alpha, "config", "user.name", "Kepler")
      File.write(File.join(alpha, "README.md"), "synthetic\n")
      assert system("git", "-C", alpha, "add", "README.md")
      assert system("git", "-C", alpha, "commit", "-qm", "base")
      worker_cwd = File.join(directory, "alpha-worker")
      assert system("git", "-C", alpha, "worktree", "add", "-q", "-b", "alpha-worker", worker_cwd)

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
          "authorization_boundary" => "No remote writes.",
          "creation_method" => "kepler-bootstrap-worker-task",
          "bootstrap_schema_version" => "kepler.worker-task-bootstrap/v1",
          "bootstrap_task_id" => "task-alpha-bootstrap-001",
          "bootstrap_expected_runtime_project_id" => "runtime-alpha-001",
          "bootstrap_actual_runtime_project_id" => "runtime-alpha-001",
          "configuration_verification_schema_version" => "kepler.worker-task-verification/v1",
          "configuration_verified" => true,
          "configuration_verified_task_id" => "task-alpha-001",
          "configuration_verified_before_prompt" => true,
          "configuration_verified_runtime_project_id" => "runtime-alpha-001",
          "post_delivery_project_verification_schema_version" => "kepler.worker-task-verification/v1",
          "post_delivery_project_verified" => true,
          "post_delivery_project_verified_task_id" => "task-alpha-001",
          "post_delivery_verified_runtime_project_id" => "runtime-alpha-001",
          "post_delivery_verified_empty" => false,
          "configuration_mode" => "global-config",
          "permission_profile" => nil,
          "sandbox_mode" => "danger-full-access",
          "approval_policy" => "on-request",
          "context_pack_id" => context.dig("metadata", "id"),
          "context_pack_estimated_tokens" => context.dig("metadata", "estimated_tokens"),
          "context_pack_token_budget" => context.dig("metadata", "token_budget"),
          "dispatch_execution" => "current-control-task",
          "intermediary_dispatch_task_created" => false,
          "dispatch_owner_task_id" => "task-control-001",
          "dispatch_owner_project_path" => root,
          "prompt_delivery_method" => "codex-thread-message",
          "project_association_verification_source" => "live-project-and-task-list",
          "project_association_before" => {
            "runtime_project_id" => "runtime-alpha-001",
            "project_path" => alpha,
            "task_cwd" => worker_cwd
          },
          "project_association_after" => {
            "runtime_project_id" => "runtime-alpha-001",
            "project_path" => alpha,
            "task_cwd" => worker_cwd
          },
          "herdr_attachment" => herdr_attachment(task_id: "task-alpha-001", worker_cwd: worker_cwd)
        }
      )
      mismatched_receipt = File.join(root, "mismatched-receipt.yaml")
      mismatched = Kepler::Support.load_data(receipt)
      mismatched["context_pack_estimated_tokens"] += 1
      Kepler::Support.atomic_yaml(mismatched_receipt, mismatched)
      mismatch_error = assert_raises(Kepler::ValidationError) do
        store.record_dispatch(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: mismatched_receipt
        )
      end
      assert_includes mismatch_error.message, "does not match the compiled artifact"

      wrong_owner_receipt = File.join(root, "wrong-owner-receipt.yaml")
      wrong_owner = Kepler::Support.load_data(receipt)
      wrong_owner["dispatch_owner_project_path"] = alpha
      Kepler::Support.atomic_yaml(wrong_owner_receipt, wrong_owner)
      owner_error = assert_raises(Kepler::ValidationError) do
        store.record_dispatch(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: wrong_owner_receipt
        )
      end
      assert_includes owner_error.message, "owner is not the current control project"

      primary_checkout_receipt = File.join(root, "primary-checkout-receipt.yaml")
      primary_checkout = Kepler::Support.load_data(receipt)
      primary_checkout["project_association_before"]["task_cwd"] = alpha
      primary_checkout["project_association_after"]["task_cwd"] = alpha
      primary_checkout["herdr_attachment"] = herdr_attachment(
        task_id: "task-alpha-001",
        worker_cwd: alpha
      )
      Kepler::Support.atomic_yaml(primary_checkout_receipt, primary_checkout)
      worktree_error = assert_raises(Kepler::ValidationError) do
        store.record_dispatch(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: primary_checkout_receipt
        )
      end
      assert_includes worktree_error.message, "not a registered non-primary checkout"

      store.record_dispatch(
        id: "synthetic-plan",
        revision: 1,
        unit_id: "alpha-change",
        receipt_path: receipt
      )
      active_cleanup_error = assert_raises(Kepler::ValidationError) do
        store.prepare_cleanup(id: "synthetic-plan", revision: 1)
      end
      assert_includes active_cleanup_error.message, "active or incomplete"
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
      assert_equal "ingested", summary["result_ingestion"]
      assert_equal context.dig("metadata", "estimated_tokens"), summary.dig("token_efficiency", "context_pack_estimated_tokens")
      assert_operator summary.dig("token_efficiency", "worker_result_estimated_tokens"), :>, 0
      assert_equal "unavailable", summary.dig("token_efficiency", "runtime_token_usage")

      repeated = store.ingest_result(worker_result)
      assert_equal "completed", repeated["state"]
      assert_equal "unchanged", repeated["result_ingestion"]

      cleanup_envelope = store.prepare_cleanup(id: "synthetic-plan", revision: 1)
      cleanup_unit = cleanup_envelope.fetch("units").first
      assert_equal true, cleanup_unit.dig("requested_action", "remove_worktree")
      assert_equal "task-alpha-001", cleanup_unit["task_id"]
      assert_equal "alpha-change", cleanup_unit.dig("herdr_attachment", "agent_name")
      preserve_envelope = store.prepare_cleanup(id: "synthetic-plan", revision: 1, preserve_worktrees: true)
      assert_equal false, preserve_envelope.dig("units", 0, "requested_action", "remove_worktree")
      stored_dispatch_path = File.join(root, store.load("synthetic-plan").dig("units", 0, "dispatch_receipt"))
      stored_dispatch = Kepler::Support.load_data(stored_dispatch_path)
      without_attachment = stored_dispatch.dup
      without_attachment.delete("herdr_attachment")
      Kepler::Support.atomic_yaml(stored_dispatch_path, without_attachment)
      no_attachment_error = assert_raises(Kepler::ValidationError) do
        store.prepare_cleanup(id: "synthetic-plan", revision: 1)
      end
      assert_includes no_attachment_error.message, "no owned Herdr attachment"
      Kepler::Support.atomic_yaml(stored_dispatch_path, stored_dispatch)
      cleanup_result = File.join(root, "cleanup-result.json")
      File.write(
        cleanup_result,
        JSON.pretty_generate(
          {
            "schemaVersion" => "kepler.worker-cleanup/v1",
            "taskId" => "task-alpha-001",
            "runtimeProjectId" => "runtime-alpha-001",
            "projectPath" => alpha,
            "workerCwd" => worker_cwd,
            "mode" => "worktree",
            "herdrAttachment" => herdr_attachment(task_id: "task-alpha-001", worker_cwd: worker_cwd),
            "herdrWorkspaceClosed" => true,
            "taskArchived" => true,
            "removeWorktreeRequested" => true,
            "worktreeRemoved" => true,
            "branchPreserved" => true
          }
        )
      )
      invalid_cleanup = JSON.parse(File.read(cleanup_result))
      invalid_cleanup["taskId"] = "other-task"
      invalid_cleanup_path = File.join(root, "invalid-cleanup.json")
      File.write(invalid_cleanup_path, JSON.pretty_generate(invalid_cleanup))
      task_mismatch = assert_raises(Kepler::ValidationError) do
        store.record_cleanup(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: invalid_cleanup_path
        )
      end
      assert_includes task_mismatch.message, "resumed task does not match"
      invalid_cleanup = JSON.parse(File.read(cleanup_result))
      invalid_cleanup["projectPath"] = root
      File.write(invalid_cleanup_path, JSON.pretty_generate(invalid_cleanup))
      path_mismatch = assert_raises(Kepler::ValidationError) do
        store.record_cleanup(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: invalid_cleanup_path
        )
      end
      assert_includes path_mismatch.message, "project_path does not match"
      invalid_cleanup = JSON.parse(File.read(cleanup_result))
      invalid_cleanup["branchPreserved"] = false
      File.write(invalid_cleanup_path, JSON.pretty_generate(invalid_cleanup))
      action_mismatch = assert_raises(Kepler::ValidationError) do
        store.record_cleanup(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: invalid_cleanup_path
        )
      end
      assert_includes action_mismatch.message, "preserve the branch"
      cleaned = store.record_cleanup(
        id: "synthetic-plan",
        revision: 1,
        unit_id: "alpha-change",
        receipt_path: cleanup_result
      )
      assert_equal "recorded", cleaned["cleanup_recording"]
      assert_equal "recorded", cleaned.dig("unit_status", 0, "cleanup_status")
      assert_equal true, cleaned.dig("unit_status", 0, "cleanup", "worktree_removed")
      repeated_cleanup = store.record_cleanup(
        id: "synthetic-plan",
        revision: 1,
        unit_id: "alpha-change",
        receipt_path: cleanup_result
      )
      assert_equal "unchanged", repeated_cleanup["cleanup_recording"]
      already_cleaned = assert_raises(Kepler::ValidationError) do
        store.prepare_cleanup(id: "synthetic-plan", revision: 1, unit_id: "alpha-change")
      end
      assert_includes already_cleaned.message, "already has a recorded CleanupReceipt"
      no_remaining = assert_raises(Kepler::ValidationError) do
        store.prepare_cleanup(id: "synthetic-plan", revision: 1)
      end
      assert_includes no_remaining.message, "no terminal Plan units"

      output = StringIO.new
      status = Kepler::CLI.new(root: root, out: output, err: StringIO.new).run(["status", "--json"])
      assert_equal 0, status
      current = JSON.parse(output.string).fetch("current_plan")
      assert_equal "synthetic-plan", current["plan_id"]
      assert_equal "completed", current["state"]
      assert_equal "unavailable", current.dig("token_efficiency", "runtime_token_usage")
      assert_equal "recorded", current.dig("unit_status", 0, "cleanup_status")
    end
  end

  def test_context_pack_omits_units_outside_the_direct_dependency_edges
    configured_control do |root, config, _directory, _result, _alpha, _beta|
      source = File.join(root, "plan.yaml")
      plan = plan_document
      plan["units"] << {
        "id" => "dependent-change",
        "workspace" => "beta",
        "domain" => "root",
        "paths" => ["."],
        "dependencies" => ["alpha-change"],
        "status" => { "state" => "planned" }
      }
      plan["units"] << {
        "id" => "unrelated-change",
        "workspace" => "beta",
        "domain" => "root",
        "paths" => ["."],
        "dependencies" => [],
        "status" => { "state" => "planned" }
      }
      Kepler::Support.atomic_yaml(source, plan)
      store = Kepler::PlanStore.new(config)
      store.apply(source)

      envelope = store.prepare_dispatch(
        id: "synthetic-plan",
        revision: 1,
        unit_id: "alpha-change"
      ).fetch("units").first
      context = Kepler::Support.load_data(File.join(root, envelope["context_pack_path"]))
      assert_equal ["dependent-change"], context.fetch("related_work").map { |item| item["unit"] }
      assert_equal 1, context.dig("telemetry", "related_unit_count")
      assert_equal 1, context.dig("telemetry", "omitted_unrelated_unit_count")
    end
  end

  def test_dispatch_receipt_rejects_direct_creation_and_false_configuration_evidence
    configured_control do |root, config, _directory, _result, alpha, _beta|
      source = File.join(root, "plan.yaml")
      Kepler::Support.atomic_yaml(source, plan_document)
      store = Kepler::PlanStore.new(config)
      store.apply(source)
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
          "authorization_boundary" => "No remote writes.",
          "creation_method" => "direct-project-worktree",
          "bootstrap_schema_version" => "kepler.worker-task-bootstrap/v1",
          "bootstrap_task_id" => "task-alpha-bootstrap-001",
          "bootstrap_expected_runtime_project_id" => "runtime-alpha-001",
          "bootstrap_actual_runtime_project_id" => "runtime-alpha-001",
          "configuration_verification_schema_version" => "kepler.worker-task-verification/v1",
          "configuration_verified" => true,
          "configuration_verified_task_id" => "task-alpha-001",
          "configuration_verified_before_prompt" => true,
          "configuration_verified_runtime_project_id" => "runtime-alpha-001",
          "post_delivery_project_verification_schema_version" => "kepler.worker-task-verification/v1",
          "post_delivery_project_verified" => true,
          "post_delivery_project_verified_task_id" => "task-alpha-001",
          "post_delivery_verified_runtime_project_id" => "runtime-alpha-001",
          "post_delivery_verified_empty" => false,
          "configuration_mode" => "global-config",
          "permission_profile" => nil,
          "sandbox_mode" => "danger-full-access",
          "approval_policy" => "on-request",
          "context_pack_id" => "ctx-synthetic-plan-alpha-change-r1",
          "context_pack_estimated_tokens" => 1_000,
          "context_pack_token_budget" => 2_000,
          "dispatch_execution" => "current-control-task",
          "intermediary_dispatch_task_created" => false,
          "dispatch_owner_task_id" => "task-control-001",
          "dispatch_owner_project_path" => root,
          "prompt_delivery_method" => "codex-thread-message",
          "project_association_verification_source" => "live-project-and-task-list",
          "project_association_before" => {
            "runtime_project_id" => "runtime-alpha-001",
            "project_path" => alpha,
            "task_cwd" => alpha
          },
          "project_association_after" => {
            "runtime_project_id" => "runtime-alpha-001",
            "project_path" => alpha,
            "task_cwd" => alpha
          }
        }
      )
      error = assert_raises(Kepler::ValidationError) do
        store.record_dispatch(
          id: "synthetic-plan",
          revision: 1,
          unit_id: "alpha-change",
          receipt_path: receipt
        )
      end
      assert_includes error.message, "must use the Kepler worker bootstrap"
      assert_equal "ready", store.summary(store.load("synthetic-plan")).dig("unit_status", 0, "state")
    end
  end

  def test_herdr_attachment_contract_rejects_incompatible_or_reassociated_workers
    attachment = herdr_attachment(task_id: "task-alpha-001", worker_cwd: "/synthetic/alpha")
    assert_equal attachment, Kepler::Contracts.herdr_attachment!(
      attachment,
      task_id: "task-alpha-001",
      worker_cwd: "/synthetic/alpha"
    )
    incompatible = attachment.merge("protocol" => 18)
    protocol_error = assert_raises(Kepler::ValidationError) do
      Kepler::Contracts.herdr_attachment!(
        incompatible,
        task_id: "task-alpha-001",
        worker_cwd: "/synthetic/alpha"
      )
    end
    assert_includes protocol_error.message, "at least 19"
    reassociated = attachment.merge("resumed_task_id" => "task-other")
    task_error = assert_raises(Kepler::ValidationError) do
      Kepler::Contracts.herdr_attachment!(
        reassociated,
        task_id: "task-alpha-001",
        worker_cwd: "/synthetic/alpha"
      )
    end
    assert_includes task_error.message, "does not match the worker task"
  end

  def test_dispatch_receipt_rejects_verification_for_another_task
    receipt = {
      "api_version" => "kepler.dev/v1",
      "kind" => "DispatchReceipt",
      "task_id" => "task-alpha-001",
      "runtime_project_id" => "runtime-alpha-001",
      "project_path" => "/synthetic/alpha",
      "mode" => "worktree",
      "requested_model" => "gpt-5.6-terra",
      "effective_model" => "gpt-5.6-terra",
      "requested_thinking" => "high",
      "effective_thinking" => "high",
      "authorization_boundary" => "No remote writes.",
      "creation_method" => "kepler-bootstrap-worker-task",
      "bootstrap_schema_version" => "kepler.worker-task-bootstrap/v1",
      "bootstrap_task_id" => "task-alpha-bootstrap-001",
      "bootstrap_expected_runtime_project_id" => "runtime-alpha-001",
      "bootstrap_actual_runtime_project_id" => "runtime-alpha-001",
      "configuration_verification_schema_version" => "kepler.worker-task-verification/v1",
      "configuration_verified" => true,
      "configuration_verified_task_id" => "different-task",
      "configuration_verified_before_prompt" => true,
      "configuration_verified_runtime_project_id" => "runtime-alpha-001",
      "post_delivery_project_verification_schema_version" => "kepler.worker-task-verification/v1",
      "post_delivery_project_verified" => true,
      "post_delivery_project_verified_task_id" => "task-alpha-001",
      "post_delivery_verified_runtime_project_id" => "runtime-alpha-001",
      "post_delivery_verified_empty" => false,
      "configuration_mode" => "global-config",
      "permission_profile" => nil,
      "sandbox_mode" => "danger-full-access",
      "approval_policy" => "on-request",
      "context_pack_id" => "ctx-synthetic-plan-alpha-change-r1",
      "context_pack_estimated_tokens" => 1_000,
      "context_pack_token_budget" => 2_000,
      "dispatch_execution" => "current-control-task",
      "intermediary_dispatch_task_created" => false,
      "dispatch_owner_task_id" => "task-control-001",
      "dispatch_owner_project_path" => "/synthetic/control",
      "prompt_delivery_method" => "codex-thread-message",
      "project_association_verification_source" => "live-project-and-task-list",
      "project_association_before" => {
        "runtime_project_id" => "runtime-alpha-001",
        "project_path" => "/synthetic/alpha",
        "task_cwd" => "/synthetic/alpha"
      },
      "project_association_after" => {
        "runtime_project_id" => "runtime-alpha-001",
        "project_path" => "/synthetic/alpha",
        "task_cwd" => "/synthetic/alpha"
      }
    }
    error = assert_raises(Kepler::ValidationError) do
      Kepler::Contracts.dispatch_receipt!(receipt)
    end
    assert_includes error.message, "does not match the final worker task"
  end

  def test_dispatch_receipt_rejects_intermediary_dispatch_and_project_reassociation
    receipt = {
      "api_version" => "kepler.dev/v1",
      "kind" => "DispatchReceipt",
      "task_id" => "task-alpha-001",
      "runtime_project_id" => "runtime-alpha-001",
      "project_path" => "/synthetic/alpha",
      "mode" => "worktree",
      "requested_model" => "gpt-5.6-terra",
      "effective_model" => "gpt-5.6-terra",
      "requested_thinking" => "high",
      "effective_thinking" => "high",
      "authorization_boundary" => "No remote writes.",
      "creation_method" => "kepler-bootstrap-worker-task",
      "bootstrap_schema_version" => "kepler.worker-task-bootstrap/v1",
      "bootstrap_task_id" => "task-alpha-bootstrap-001",
      "bootstrap_expected_runtime_project_id" => "runtime-alpha-001",
      "bootstrap_actual_runtime_project_id" => "runtime-alpha-001",
      "configuration_verification_schema_version" => "kepler.worker-task-verification/v1",
      "configuration_verified" => true,
      "configuration_verified_task_id" => "task-alpha-001",
      "configuration_verified_before_prompt" => true,
      "configuration_verified_runtime_project_id" => "runtime-alpha-001",
      "post_delivery_project_verification_schema_version" => "kepler.worker-task-verification/v1",
      "post_delivery_project_verified" => true,
      "post_delivery_project_verified_task_id" => "task-alpha-001",
      "post_delivery_verified_runtime_project_id" => "runtime-alpha-001",
      "post_delivery_verified_empty" => false,
      "configuration_mode" => "global-config",
      "permission_profile" => nil,
      "sandbox_mode" => "danger-full-access",
      "approval_policy" => "on-request",
      "context_pack_id" => "ctx-synthetic-plan-alpha-change-r1",
      "context_pack_estimated_tokens" => 1_000,
      "context_pack_token_budget" => 2_000,
      "dispatch_execution" => "separate-dispatch-task",
      "intermediary_dispatch_task_created" => true,
      "dispatch_owner_task_id" => "task-dispatch-001",
      "dispatch_owner_project_path" => "/synthetic/control",
      "prompt_delivery_method" => "collaboration-agent-resume",
      "project_association_verification_source" => "live-project-and-task-list",
      "project_association_before" => {
        "runtime_project_id" => "runtime-alpha-001",
        "project_path" => "/synthetic/alpha",
        "task_cwd" => "/synthetic/worktree-alpha"
      },
      "project_association_after" => {
        "runtime_project_id" => "runtime-control-001",
        "project_path" => "/synthetic/control",
        "task_cwd" => "/synthetic/worktree-alpha"
      }
    }
    error = assert_raises(Kepler::ValidationError) do
      Kepler::Contracts.dispatch_receipt!(receipt)
    end
    assert_includes error.message, "without an intermediary dispatcher"

    receipt["dispatch_execution"] = "current-control-task"
    receipt["intermediary_dispatch_task_created"] = false
    receipt["dispatch_owner_task_id"] = "task-control-001"
    receipt["prompt_delivery_method"] = "codex-thread-message"
    reassociation_error = assert_raises(Kepler::ValidationError) do
      Kepler::Contracts.dispatch_receipt!(receipt)
    end
    assert_includes reassociation_error.message, "association drifted"

    receipt["project_association_after"] = receipt["project_association_before"].dup
    receipt["post_delivery_verified_runtime_project_id"] = "runtime-control-001"
    app_server_error = assert_raises(Kepler::ValidationError) do
      Kepler::Contracts.dispatch_receipt!(receipt)
    end
    assert_includes app_server_error.message, "app-server project identity"
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

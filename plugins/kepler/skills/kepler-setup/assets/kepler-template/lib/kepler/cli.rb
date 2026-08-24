# frozen_string_literal: true

require "optparse"
require_relative "architecture_map_store"
require_relative "bridge_bulk_store"
require_relative "doctor"
require_relative "memory_store"
require_relative "plan_store"
require_relative "repo_planner"
require_relative "repository_store"
require_relative "route_planner"
require_relative "setup_store"

module Kepler
  class CLI
    def initialize(root:, out: $stdout, err: $stderr)
      @root = root
      @out = out
      @err = err
    end

    def run(argv)
      arguments = argv.dup
      command = arguments.shift || "help"
      return help if %w[help -h --help].include?(command)

      config = Config.new(root: @root)
      case command
      when "doctor" then doctor(config, arguments)
      when "status" then status(config, arguments)
      when "setup" then setup(config, arguments)
      when "route" then route(config, arguments)
      when "repo" then repo(config, arguments)
      when "bridge" then bridge(config, arguments)
      when "architecture" then architecture(config, arguments)
      when "plan" then plan(config, arguments)
      when "dispatch" then dispatch(config, arguments)
      when "cleanup" then cleanup(config, arguments)
      when "review" then review(config, arguments)
      when "result" then result(config, arguments)
      when "memory" then memory(config, arguments)
      else raise UsageError, "unknown command: #{command}"
      end
    rescue UsageError, OptionParser::ParseError => e
      @err.puts("Error: #{e.message}")
      @err.puts("Run bin/kepler help for usage.")
      2
    rescue ConfigurationError, ValidationError => e
      @err.puts("Error: #{e.message}")
      1
    rescue Interrupt
      @err.puts("Interrupted")
      130
    end

    private

    def doctor(config, argv)
      options = { json: false, strict: false }
      OptionParser.new do |parser|
        parser.on("--json") { options[:json] = true }
        parser.on("--strict") { options[:strict] = true }
      end.parse!(argv)
      empty!(argv)
      result = Doctor.new(config).run
      options[:json] ? json(result) : print_doctor(result)
      return 1 if result.dig("summary", "errors").positive?
      return 1 if options[:strict] && result.dig("summary", "warnings").positive?

      0
    end

    def status(config, argv)
      options = { json: false, write: false }
      OptionParser.new do |parser|
        parser.on("--json") { options[:json] = true }
        parser.on("--write") { options[:write] = true }
      end.parse!(argv)
      empty!(argv)
      result = Doctor.new(config).run
      current_plan_path = File.join(config.plan_dir, "current")
      result["current_plan"] = if File.file?(current_plan_path)
                                 store = PlanStore.new(config)
                                 store.summary(store.load)
                               end
      if options[:write]
        path = File.join(config.report_dir, "STATUS.md")
        Support.atomic_write(path, status_markdown(result))
        result["report"] = Support.relative_path(config.root, path)
      end
      options[:json] ? json(result) : @out.puts(status_markdown(result))
      0
    end

    def setup(config, argv)
      subcommand = argv.shift
      options = { project_ids: [], confirm: false, json: false }
      OptionParser.new do |parser|
        parser.on("--project-catalog FILE") { |value| options[:project_catalog] = value }
        parser.on("--project-id ID") { |value| options[:project_ids] << value }
        parser.on("--architecture-map FILE") { |value| options[:architecture_map] = value }
        parser.on("--confirm") { options[:confirm] = true }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--project-catalog is required" unless options[:project_catalog]

      json_output = options.delete(:json)
      store = SetupStore.new(config)
      result = case subcommand
               when "plan"
                 options.delete(:confirm)
                 options.delete(:architecture_map)
                 store.plan(**options)
               when "apply" then store.apply(**options)
               else raise UsageError, "setup requires plan or apply"
               end
      if json_output
        json(result)
      else
        @out.puts(subcommand == "plan" ? "Saved project selection preview" : "Saved projects configured")
        result.fetch("projects").each do |item|
          @out.puts("- #{item['logical_key']}: #{item['runtime_project_id']} (#{item['path']})")
        end
        @out.puts(result["next"])
      end
      0
    end

    def route(config, argv)
      raise UsageError, "route requires plan" unless argv.shift == "plan"

      options = { json: false }
      OptionParser.new do |parser|
        parser.on("--workspace NAME") { |value| options[:workspace] = value }
        parser.on("--domain NAME") { |value| options[:domain] = value }
        parser.on("--work-type TYPE") { |value| options[:work_type] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--workspace, --domain, and --work-type are required" unless options[:workspace] && options[:domain] && options[:work_type]

      json_output = options.delete(:json)
      result = RoutePlanner.new(config).plan(**options)
      if json_output
        json(result)
      else
        @out.puts("Read-only routing plan")
        @out.puts("Project: #{result['logical_project_key']} (#{result['project_path']})")
        @out.puts("Runtime project ID: #{result['runtime_project_id']}")
        @out.puts("Mode: #{result['mode']}")
        @out.puts("Dispatch required: #{result['dispatch_required'] ? 'yes' : 'no'}")
        result["steps"].each_with_index { |step, index| @out.puts("#{index + 1}. #{step}") }
        @out.puts("No project, task, repository, or file was changed.")
      end
      0
    end

    def repo(config, argv)
      subcommand = argv.shift
      case subcommand
      when "plan" then repo_plan(config, argv)
      when "onboard" then repo_onboard(config, argv)
      else raise UsageError, "repo requires plan or onboard"
      end
    end

    def repo_plan(config, argv)
      options = { json: false }
      OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload_name] = value }
        parser.on("--provider NAME") { |value| options[:provider_name] = value }
        parser.on("--repo LOCATOR") { |value| options[:locator] = value }
        parser.on("--name NAME") { |value| options[:name] = value }
        parser.on("--owner OWNER") { |value| options[:owner] = value }
        parser.on("--default-branch BRANCH") { |value| options[:default_branch] = value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--workload, --provider, and --repo are required" unless options[:workload_name] && options[:provider_name] && options[:locator]

      json_output = options.delete(:json)
      result = RepoPlanner.new(config).plan(**options)
      if json_output
        json(result)
      else
        @out.puts("Read-only repository plan")
        @out.puts("Target: #{result['target']}")
        result["steps"].each_with_index { |step, index| @out.puts("#{index + 1}. #{step}") }
        @out.puts("No files, remotes, projects, or repositories were changed.")
      end
      0
    end

    def repo_onboard(config, argv)
      options = { bridge_mode: "reference", acknowledge_repo_native: false }
      OptionParser.new do |parser|
        parser.on("--workload NAME") { |value| options[:workload_name] = value }
        parser.on("--provider NAME") { |value| options[:provider_name] = value }
        parser.on("--repo LOCATOR") { |value| options[:locator] = value }
        parser.on("--id ID") { |value| options[:repository_id] = value }
        parser.on("--name NAME") { |value| options[:name] = value }
        parser.on("--url URL") { |value| options[:url] = value }
        parser.on("--owner OWNER") { |value| options[:owner] = value }
        parser.on("--default-branch BRANCH") { |value| options[:default_branch] = value }
        parser.on("--bridge-mode MODE") { |value| options[:bridge_mode] = value }
        parser.on("--bridge-profile PROFILE") { |value| options[:bridge_profile] = value }
        parser.on("--acknowledge-repo-native") { options[:acknowledge_repo_native] = true }
      end.parse!(argv)
      empty!(argv)
      required = %i[workload_name provider_name locator repository_id]
      raise UsageError, required.map { |item| "--#{item.to_s.tr('_', '-')}" }.join(", ") + " are required" unless required.all? { |item| options[item] }

      result = RepositoryStore.new(config).onboard(**options)
      json(result)
      0
    end

    def bridge(config, argv)
      subcommand = argv.shift
      options = {
        mode: nil,
        profile: nil,
        all: false,
        failure_policy: "stop",
        acknowledge_repo_native: false,
        authorize_repo_native: [],
        json: false
      }
      OptionParser.new do |parser|
        parser.on("--repo-id ID") { |value| options[:repository_id] = value }
        parser.on("--mode MODE") { |value| options[:mode] = value }
        parser.on("--profile PROFILE") { |value| options[:profile] = value }
        parser.on("--all") { options[:all] = true }
        parser.on("--failure-policy POLICY") { |value| options[:failure_policy] = value }
        parser.on("--acknowledge-repo-native") { options[:acknowledge_repo_native] = true }
        parser.on("--authorize-repo-native ID") { |value| options[:authorize_repo_native] << value }
        parser.on("--json") { options[:json] = true }
      end.parse!(argv)
      empty!(argv)
      if options[:all] == !!options[:repository_id]
        raise UsageError, "choose exactly one of --repo-id or --all"
      end
      if options[:all] && (options[:mode] || options[:profile] || options[:acknowledge_repo_native])
        raise UsageError, "--all reads mode and profile from declarations; use --authorize-repo-native ID per repository"
      end
      json_output = options.delete(:json)
      if options.delete(:all)
        failure_policy = options.delete(:failure_policy)
        authorize = options.delete(:authorize_repo_native)
        result = case subcommand
                 when "plan"
                   BridgeBulkStore.new(config).plan(failure_policy: failure_policy)
                 when "install"
                   BridgeBulkStore.new(config).install_all(
                     failure_policy: failure_policy,
                     authorize_repo_native: authorize
                   )
                 else raise UsageError, "bridge requires plan or install"
                 end
      else
        options.delete(:failure_policy)
        options.delete(:authorize_repo_native)
        options[:mode] ||= "reference"
        result = case subcommand
                 when "plan"
                   options.delete(:acknowledge_repo_native)
                   BridgeStore.new(config).plan(**options)
                 when "install"
                   BridgeStore.new(config).install(**options)
                 else raise UsageError, "bridge requires plan or install"
                 end
      end
      json_output ? json(result) : result.each { |key, value| @out.puts("#{key}: #{value}") }
      result.is_a?(Hash) && result.key?("ok") && !result["ok"] ? 1 : 0
    end

    def architecture(config, argv)
      subcommand = argv.shift
      store = ArchitectureMapStore.new(config)
      case subcommand
      when "confirm"
        source = argv.shift
        raise UsageError, "architecture confirm requires FILE" unless source
        empty!(argv)
        json(store.confirm(source))
      when "show"
        empty!(argv)
        json(store.load)
      else raise UsageError, "architecture requires confirm or show"
      end
      0
    end

    def plan(config, argv)
      subcommand = argv.shift
      store = PlanStore.new(config)
      case subcommand
      when "apply"
        source = argv.shift
        raise UsageError, "plan apply requires FILE" unless source
        options = {}
        OptionParser.new { |parser| parser.on("--expect-revision N", Integer) { |value| options[:expected_revision] = value } }.parse!(argv)
        empty!(argv)
        json(store.apply(source, **options))
      when "show"
        id = argv.shift
        empty!(argv)
        json(store.load(id))
      when "status"
        id = argv.shift
        empty!(argv)
        json(store.summary(store.load(id)))
      else raise UsageError, "plan requires apply, show, or status"
      end
      0
    end

    def dispatch(config, argv)
      subcommand = argv.shift
      id = argv.shift
      raise UsageError, "dispatch #{subcommand || 'command'} requires PLAN_ID" unless id
      options = {}
      OptionParser.new do |parser|
        parser.on("--revision N", Integer) { |value| options[:revision] = value }
        parser.on("--unit ID") { |value| options[:unit_id] = value }
        parser.on("--budget N", Integer) { |value| options[:budget] = value }
        parser.on("--receipt FILE") { |value| options[:receipt_path] = value }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--revision is required" unless options[:revision]
      store = PlanStore.new(config)
      value = case subcommand
              when "prepare"
                options.delete(:receipt_path)
                store.prepare_dispatch(id: id, **options)
              when "record"
                raise UsageError, "dispatch record requires --unit and --receipt" unless options[:unit_id] && options[:receipt_path]
                options.delete(:budget)
                store.record_dispatch(id: id, **options)
              else raise UsageError, "dispatch requires prepare or record"
              end
      json(value)
      0
    end

    def result(config, argv)
      raise UsageError, "result requires ingest" unless argv.shift == "ingest"
      source = argv.shift
      raise UsageError, "result ingest requires FILE" unless source
      empty!(argv)
      json(PlanStore.new(config).ingest_result(source))
      0
    end

    def cleanup(config, argv)
      subcommand = argv.shift
      id = argv.shift
      raise UsageError, "cleanup #{subcommand || 'command'} requires PLAN_ID" unless id
      options = { preserve_worktrees: false }
      OptionParser.new do |parser|
        parser.on("--revision N", Integer) { |value| options[:revision] = value }
        parser.on("--unit ID") { |value| options[:unit_id] = value }
        parser.on("--receipt FILE") { |value| options[:receipt_path] = value }
        parser.on("--preserve-worktrees") { options[:preserve_worktrees] = true }
      end.parse!(argv)
      empty!(argv)
      raise UsageError, "--revision is required" unless options[:revision]
      store = PlanStore.new(config)
      value = case subcommand
              when "prepare"
                options.delete(:receipt_path)
                store.prepare_cleanup(id: id, **options)
              when "record"
                raise UsageError, "cleanup record requires --unit and --receipt" unless options[:unit_id] && options[:receipt_path]
                options.delete(:preserve_worktrees)
                store.record_cleanup(id: id, **options)
              else raise UsageError, "cleanup requires prepare or record"
              end
      json(value)
      0
    end

    def review(config, argv)
      id = argv.shift
      empty!(argv)
      store = PlanStore.new(config)
      plan = store.load(id)
      result = store.summary(plan).merge(
        "review_only" => true,
        "fixes_authorized" => false,
        "transcript_sync" => false,
        "evidence" => plan["units"].map { |unit| unit["worker_result"] }.compact
      )
      json(result)
      0
    end

    def memory(config, argv)
      subcommand = argv.shift
      store = MemoryStore.new(config)
      case subcommand
      when "ingest"
        source = argv.shift
        raise UsageError, "memory ingest requires FILE" unless source
        empty!(argv)
        json(store.ingest(source))
      when "query"
        options = { limit: 8, include_work: false }
        OptionParser.new do |parser|
          parser.on("--text TEXT") { |value| options[:text] = value }
          parser.on("--workspace ID") { |value| options[:workspace] = value }
          parser.on("--domain ID") { |value| options[:domain] = value }
          parser.on("--limit N", Integer) { |value| options[:limit] = value }
          parser.on("--include-work") { options[:include_work] = true }
        end.parse!(argv)
        empty!(argv)
        raise UsageError, "memory query requires --text" unless options[:text]
        json(store.query(**options))
      else raise UsageError, "memory requires ingest or query"
      end
      0
    end

    def help
      @out.puts <<~HELP
        Kepler command line

        Usage:
          bin/kepler help
          bin/kepler doctor [--json] [--strict]
          bin/kepler status [--json] [--write]
          bin/kepler setup plan --project-catalog FILE --project-id ID [--project-id ID ...] [--json]
          bin/kepler setup apply --project-catalog FILE --project-id ID [--project-id ID ...] --confirm [--json]
          bin/kepler route plan --workspace NAME --domain NAME --work-type TYPE [--json]
          bin/kepler repo plan --workload NAME --provider NAME --repo LOCATOR [--name NAME] [--owner OWNER] [--default-branch BRANCH] [--json]
          bin/kepler repo onboard --workload NAME --provider NAME --repo LOCATOR --id ID [--name NAME] [--url URL] [--owner OWNER] [--default-branch BRANCH] [--bridge-mode MODE] [--acknowledge-repo-native]
          bin/kepler bridge plan --repo-id ID [--mode MODE] [--profile PROFILE] [--json]
          bin/kepler bridge plan --all [--failure-policy stop|continue] [--json]
          bin/kepler bridge install --repo-id ID [--mode MODE] [--profile PROFILE] [--acknowledge-repo-native] [--json]
          bin/kepler bridge install --all [--failure-policy stop|continue] [--authorize-repo-native ID] [--json]
          bin/kepler architecture confirm FILE
          bin/kepler architecture show
          bin/kepler plan apply FILE [--expect-revision N]
          bin/kepler plan show [PLAN_ID]
          bin/kepler plan status [PLAN_ID]
          bin/kepler dispatch prepare PLAN_ID --revision N [--unit ID] [--budget N]
          bin/kepler dispatch record PLAN_ID --revision N --unit ID --receipt FILE
          bin/kepler cleanup prepare PLAN_ID --revision N [--unit ID] [--preserve-worktrees]
          bin/kepler cleanup record PLAN_ID --revision N --unit ID --receipt FILE
          bin/kepler result ingest FILE
          bin/kepler review [PLAN_ID]
          bin/kepler memory ingest FILE
          bin/kepler memory query --text TEXT [--workspace ID] [--domain ID] [--limit N]

        doctor, status, setup plan, route plan, repo plan, bridge plan, cleanup prepare,
        and review are read-only.
        status --write, setup apply, repo onboard, bridge install, architecture
        confirm, plan apply, dispatch record, cleanup record, result ingest, and memory ingest
        have explicit state-changing names and write only their documented scope.
      HELP
      0
    end

    def print_doctor(result)
      summary = result.fetch("summary")
      @out.puts("Kepler doctor: #{summary['errors']} error(s), #{summary['warnings']} warning(s)")
      result.fetch("issues").each do |item|
        @out.puts("#{item['severity'].upcase} [#{item['code']}] #{item['scope']}: #{item['message']}")
      end
      @out.puts("Checked #{summary['selected_projects']} selected projects, #{summary['plans']} Plans, and #{summary['bridges']} optional bridges.")
      @out.puts("Repository ahead/behind values use local tracking refs; Doctor does not fetch.")
    end

    def status_markdown(result)
      summary = result.fetch("summary")
      lines = [
        "# Kepler Status",
        "",
        "Generated: #{result['generated_at']}",
        "",
        "- Errors: #{summary['errors']}",
        "- Warnings: #{summary['warnings']}",
        "- Repositories: #{summary['repositories']}",
        "- Selected projects: #{summary['selected_projects']}",
        "- Plans: #{summary['plans']}",
        "- Bridges: #{summary['bridges']}",
        ""
      ]
      if result["current_plan"]
        plan = result.fetch("current_plan")
        tokens = plan.fetch("token_efficiency")
        lines.concat(
          [
            "## Current Plan",
            "",
            "- ID: #{plan['plan_id']}",
            "- Revision: #{plan['revision']}",
            "- State: #{plan['state']}",
            "- Ready units: #{plan['ready_units'].empty? ? 'none' : plan['ready_units'].join(', ')}",
            "- ContextPack estimated tokens: #{tokens['context_pack_estimated_tokens']}",
            "- WorkerResult estimated tokens: #{tokens['worker_result_estimated_tokens']}",
            "- Runtime token usage: #{tokens['runtime_token_usage']}",
            ""
          ]
        )
      end
      lines.concat(
        [
          "Ahead and behind values use local tracking refs; no fetch was performed.",
          "",
          "## Findings",
          ""
        ]
      )
      lines.concat(result["issues"].empty? ? ["None."] : result["issues"].map do |item|
        "- **#{item['severity'].upcase}** `#{item['code']}` #{item['scope']}: #{item['message']}"
      end)
      "#{lines.join("\n")}\n"
    end

    def json(value)
      @out.puts(JSON.pretty_generate(value))
    end

    def empty!(argv)
      raise UsageError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    end
  end
end

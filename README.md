# Kepler

Kepler is a context-aware coordination layer for Codex. It plans engineering work across existing Codex projects, dispatches ordinary full-capability Codex workers with focused context, and preserves useful knowledge between workers and sessions.

> Sol plans. Terra dispatches. Codex executes. Kepler remembers.

Kepler solves the repeated-context problem in multi-project work. It keeps a user-confirmed architecture map, a lightweight revisioned Plan, small ContextPacks, structured WorkerResults, exact dispatch receipts, and scoped memory. Repositories remain in their existing locations and workers remain normal Codex tasks.

Kepler is not an AI runtime, background daemon, monorepo manager, workflow engine, transcript synchronizer, Mission or Operation coordination layer, or restrictive context sandbox.

## How it works

- **Sol** interprets the objective, identifies domains and dependencies, revises the Plan, and compiles useful context.
- **Terra** verifies the exact Codex project and Plan revision, launches ready workers, returns receipts, and stops.
- **Plans** remember the objective, constraints, units, dependencies, readiness, receipts, and result evidence.
- **ContextPacks** give each worker a budgeted starting point. Their paths and references are never an exclusive boundary.
- **WorkerResults** return compact changes, discoveries, decisions, failed attempts, handoffs, and validation without copying transcripts.
- **Memory** stores typed, scoped, sourced, invalidatable knowledge and deliberately retrieves applicable failed attempts.

## Install

See [docs/install.md](docs/install.md). A local repository checkout can be added as a local Codex marketplace, then Kepler can be installed and loaded in a new task. Published-directory instructions will be added only after that distribution is actually available.

## Setup

Create or open a normal control project such as `Kepler-Acme`; keep application and platform monorepos as their own Codex projects. Run `/kepler setup`, confirm the exact projects, paths, domains, and relationships, then run `/kepler doctor`. Setup stores references and coordination state; it does not copy or edit connected repositories.

## Daily workflow

```text
/kepler plan
<describe the engineering outcome>

/kepler dispatch
/kepler status
```

Refine an active Plan in ordinary conversation. Enter any worker directly whenever useful. Return to the Kepler control project for cross-project status and the next ready dispatch.

See [workflow](docs/workflow.md), [commands](docs/commands.md), [architecture](docs/architecture.md), [setup](docs/setup.md), [troubleshooting](docs/troubleshooting.md), and the [contract documentation](docs/contracts/plan.md).

## Upgrade and removal

Plugin upgrades and control-project data migrations are separate. See [docs/upgrade.md](docs/upgrade.md). Uninstalling the plugin does not delete connected repositories or Kepler control-project state.

The distributable plugin is under `plugins/kepler/`; the repo-local marketplace is `.agents/plugins/marketplace.json`. Flightdeck users should read [docs/migration-from-flightdeck.md](docs/migration-from-flightdeck.md). The v1 product boundary is recorded in [ADR 0001](docs/decisions/0001-kepler-v1-redesign.md).

Maintainers: follow the [setup runbook](plugins/kepler/skills/kepler-setup/references/setup-runbook.md) and the [repository bridge runbook](plugins/kepler/skills/kepler-repo-bridge/references/configure-bridge-repos.md).

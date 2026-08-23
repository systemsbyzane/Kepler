---
name: kepler-setup
description: Generate and validate a Kepler control project, connect existing Codex projects without copying repositories, verify exact project paths, propose domains and relationships, and persist a user-confirmed ArchitectureMap. Use for /kepler setup, onboarding, or control-project validation.
---

# Kepler Setup

Use this workflow when users say **set up Kepler** or **connect repositories**,
as well as for explicit `/kepler setup` requests.

Before any setup action, read `references/setup-runbook.md` completely and
follow it end to end. The runbook is mandatory, including artifact capability
preflight, validation, project registration verification, and the installed
fresh-task acceptance boundary.

Use `scripts/bootstrap.py --target <absolute-path>` to preview setup, then add
`--apply` when generation is authorized. The bootstrap calls
`scripts/setup_kepler.py`, validates the result, and recognizes an existing
valid generated Hub as a validation-only no-op. It refuses unmanaged or
drifting non-empty targets while preserving valid configured topology,
repository declarations, workload payloads, and ignored runtime state. It
provides no merge, repair, or overwrite mode.

Before using an existing generated Hub, run
`scripts/hub_compatibility.py --hub-root <absolute-path>` with only the
capabilities required by the request. Repository discovery and connection
require `kepler.command.setup-plan.v1` and
`kepler.command.setup-connect.v1`. If either is unavailable, do not run
setup or bootstrap against that Hub; return the read-only compatibility result
and its explicit plan-and-diff migration guidance.

When the request identifies a repositories root, pass
`--repositories-root <absolute-path>` to both preview and apply. Setup then
discovers Git roots, records portable declarations, keeps exact attached paths
in ignored local state, and installs safe `reference` bridges automatically.
After exact project verification, inspect repository shape read-only, propose
workspace domains and relationships, show the proposal, and obtain user
confirmation before `bin/kepler architecture confirm FILE`. Discovery never
silently becomes durable topology.

The setup request authorizes those ordinary local writes. It does not authorize
tracked changes inside an attached repository, `repo-native` bridges, project
tasks, commits, remotes, publication, deployment, or external communication.

If no repositories root is named, finish and validate the core Hub, then ask
one question: which folder contains the repositories to connect? Users do not
need to name this skill, edit YAML, or ask separately for bridge setup.

Read `references/setup-contract.md` for provider, registration, and portability
requirements. Do not install, publish, share, or activate the plugin unless the
user separately authorizes that action.

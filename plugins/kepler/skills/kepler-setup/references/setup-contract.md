# Project-first setup contract

The generated control project stores coordination state, not source code.

- Start in a normal `Kepler-<company>` saved Codex project.
- Select only entries returned by the current live project list. Herdr uses
  `list_cli_projects`; desktop mode uses the desktop live list.
- Keep the logical Kepler key separate from the opaque runtime project ID.
- Require an exact normalized path match; a display-name match is insufficient.
- Never scan a repository root, create clone roots, or generate development,
  charts, patching, research, environments, compliance, Mission, or Operation
  topology.
- Never clone, move, import, open, or edit a selected project during setup. In
  Herdr only, `register_cli_project` may create a CLI project record for an
  exact path the user explicitly confirmed; it does not mutate the repository.
- Represent ownership with a user-confirmed ArchitectureMap. Domains and paths
  are initial, non-exclusive context and may be refined by later Plan revisions.
- Keep bridges optional. A missing bridge is valid. A configured bridge is
  strict and must fail closed on missing records, drift, or integrity errors.
- Keep automations disabled until explicitly enabled.

The project catalog comes from `codex_app.list_projects` or
`kepler_dispatch.list_cli_projects`, both using schema version 2. Never mix
opaque IDs from those runtime registries.
Persist exact IDs and real paths only after `setup apply --confirm`. A refined
proposal may be supplied with `--architecture-map FILE`; its workspace set,
opaque IDs, and exact paths must agree with the selected projects. Setup may
write the selected-project registry and ArchitectureMap inside the control
project; it may not write selected projects or create tasks.

The generated control project must pass Ruby tests, JSON/YAML/schema parsing,
Doctor, de-branding, and setup-link validation. Installed discovery, model
selection, task dispatch, create/resume behavior, and WorkerResult flow remain
fresh-task runtime acceptance checks.

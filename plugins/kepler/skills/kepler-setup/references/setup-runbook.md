# Kepler setup runbook

## 1. Resolve and validate the control project

Resolve one absolute `Kepler-<company>` target. Reject a symlink, filesystem
root, home directory, plugin source path, unmanaged non-empty directory, or
path mismatch. Preview before apply:

```text
python3 scripts/preflight.py --json
python3 scripts/bootstrap.py --target <absolute-target> --json
python3 scripts/bootstrap.py --target <absolute-target> --apply --json
```

Bootstrap may initialize only the new control project's local Git repository.
It does not select projects, install bridges or plugins, stage, commit, add a
remote, push, publish, or deploy.

## 2. Select existing saved projects

Call the live Codex project-list capability. In Herdr (`HERDR_ENV=1`), call
`list_cli_projects`; do not call a desktop-app or browser surface. Outside
Herdr, use the normal live Codex project list. Do not scan the filesystem for
repositories or open folders as an ordinary setup fallback. Show the saved
projects with label, opaque ID, exact path, project kind, host, and Git-project
flag. Obtain the user's selection.

The CLI and desktop app have distinct saved-project registries. If a repository
the user selected by an already-known exact path is absent from the CLI list,
show that exact path and ask for confirmation. Only after confirmation, call
`register_cli_project` for that path. This creates a persistent CLI project
record only; it must not scan, clone, move, open, or edit the repository.
Refresh `list_cli_projects` and use the returned CLI opaque ID. Never reuse a
desktop-only project ID in a Herdr ArchitectureMap.

Store the exact unmodified schema-v2 response from the selected runtime in
ignored local state, then run:

```text
bin/kepler setup plan \
  --project-catalog <ignored-live-project-list.json> \
  --project-id <opaque-id> [--project-id <opaque-id> ...] --json
```

The preview must report no repository scan, no selected-project mutation, no
bridge install, and the exact ID/path mapping.

## 3. Propose and confirm the ArchitectureMap

Sol may inspect selected projects read-only to propose workspace domains,
paths, facts, and relationships. Do not modify them or start workers. Present
the proposal and incorporate user refinements. Natural language may refine the
proposal but does not authorize persistence.

Save the reviewed proposal to an ignored YAML or JSON file. After explicit
confirmation, run:

```text
bin/kepler setup apply \
  --project-catalog <ignored-live-project-list.json> \
  --project-id <opaque-id> [--project-id <opaque-id> ...] \
  --architecture-map <ignored-reviewed-architecture-map.yaml> \
  --confirm --json
```

Then run `bin/kepler doctor --json`. Success requires the confirmed
ArchitectureMap and selected-project registry to agree on logical key, opaque
runtime ID, and exact normalized path.

## 4. Validate

Run the source-required validators and report exact counts:

```text
ruby -Ilib tests/kepler_test.rb
python3 scripts/validate_structured.py <absolute-target> --json
python3 scripts/scan_debranding.py <absolute-target> --allow-generated-root
python3 scripts/validate_links.py
bin/kepler doctor --json
```

Confirm the generated root contains none of `development/`, `charts/`,
`patching/`, `research/`, `environments/`, or `compliance/`. Confirm selected
project Git status and content are unchanged.

## 5. Handoff

Return the control-project path, selected logical keys, opaque IDs, exact paths,
ArchitectureMap confirmation state, validation results, and confirmation that
no selected project, bridge, plugin cache, commit, or remote was changed.

Use [installed acceptance](installed-acceptance.md) only after separate
authorization to install or change the plugin. Run it from a fresh task.

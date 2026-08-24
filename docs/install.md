# Install Kepler 1.1.0

Kepler requires a Codex build with plugin marketplaces, saved-project listing,
task create/resume, per-task model selection, and effective-model readback. The
release acceptance baseline is Codex CLI `0.149.0`.

## Stable Git marketplace

After the `v1.1.0` release tag is published, run:

```sh
codex plugin marketplace add systemsbyzane/Kepler --ref v1.1.0 --json
codex plugin list --marketplace kepler-team --available --json
codex plugin add kepler@kepler-team --json
codex plugin list --marketplace kepler-team --json
```

The structured results must identify marketplace `kepler-team`, plugin
`kepler`, version `1.1.0`, and an enabled installed record. A missing or
different identity is a failure, not a compatible alias.

## Local development

Use the repository's absolute path:

```sh
codex plugin marketplace add /absolute/path/to/Kepler --json
codex plugin list --marketplace kepler-team --available --json
codex plugin add kepler@kepler-team --json
codex plugin list --marketplace kepler-team --json
```

Use a clean `CODEX_HOME` for release acceptance. Start a fresh Codex task after
installation so skill discovery uses the installed snapshot, then open a
normal `Kepler-<company>` project and run `/kepler setup`.

## Upgrade, reinstall, and uninstall

Refresh a Git marketplace and reinstall the same plugin identity:

```sh
codex plugin marketplace upgrade kepler-team --json
codex plugin add kepler@kepler-team --json
```

Uninstall only when explicitly intended:

```sh
codex plugin remove kepler@kepler-team --json
codex plugin marketplace remove kepler-team --json
```

See [upgrade](upgrade.md) for preservation checks. Never hand-edit the plugin
cache.

## Recovery

- Marketplace-name conflict: inspect `codex plugin list --available --json`;
  remove the conflicting marketplace only after confirming its exact identity,
  then add Kepler again.
- Stale Git snapshot: run the marketplace upgrade command and reinstall.
- Plugin unavailable: verify the marketplace is `kepler-team`, the requested
  ref exists, and the available list contains `kepler` version `1.1.0`.
- Fresh task does not expose Kepler: confirm the installed enabled record,
  fully restart Codex, and create another fresh task.

Installing Kepler does not create or scan a repositories root, clone or move a
repository, register a project, generate workload directories, install a
repository bridge, edit selected-project files, deploy, publish, or contact an
external service beyond the requested marketplace fetch.

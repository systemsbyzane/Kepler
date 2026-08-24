---
name: kepler-setup
description: Generate and validate a Kepler control project, select existing saved Codex projects by opaque ID and exact path, propose ArchitectureMap domains and relationships, and persist them after confirmation. Use for /kepler setup, onboarding, or control-project validation.
---

# Kepler Setup

Read [the setup runbook](references/setup-runbook.md) completely before acting.
It is mandatory for `/kepler setup`.

Ordinary setup is project-first:

1. Generate or open a `Kepler-<company>` control project.
2. Call the live Codex project list. Show existing saved projects and let the
   user select by exact path; preserve each opaque project ID.
3. Save the unmodified project-list response to ignored local state and run
   `bin/kepler setup plan --project-catalog FILE --project-id ID ...`.
4. Inspect selected projects read-only only as needed to propose non-exclusive
   ArchitectureMap domains and relationships.
5. Show the proposal and save the reviewed version to ignored local state.
   After explicit confirmation, run the corresponding
   `setup apply ... --architecture-map FILE --confirm`, then `/kepler doctor`.

Do not ask for or scan a repositories root. Do not clone, move, import, open,
or edit selected projects. Do not create workload folders or pseudo-projects.
Bridges are optional advanced configuration and are never installed by
ordinary setup.

Use `scripts/bootstrap.py --target <absolute-path>` for a read-only preview and
add `--apply` only when generation is authorized. Read
[the setup contract](references/setup-contract.md) for identity, topology, and
mutation boundaries.

Installed-plugin behavior requires the separate
[fresh-task acceptance](references/installed-acceptance.md). Source validation
cannot satisfy that gate. Plugin installation, cache mutation, publication,
commit, and remote writes require their own explicit authorization.

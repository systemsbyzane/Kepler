# Saved-project selection

Ordinary `/kepler setup` selects projects already returned by the live Codex
project list. It never scans a repositories root or clones, moves, imports,
opens, registers, or edits a project.

```text
bin/kepler setup plan --project-catalog FILE --project-id ID [--project-id ID ...] --json
bin/kepler setup apply --project-catalog FILE --project-id ID [--project-id ID ...] --architecture-map FILE --confirm --json
```

The catalog must be the unmodified schema-v2 live-list result. A selected
project is valid only when its opaque runtime ID exists in that result and its
absolute path resolves exactly. Display names are presentation only.

Setup writes the ignored selected-project registry and confirmed
ArchitectureMap inside this control project. It does not write a selected
project and does not create tasks or bridges.

Advanced, explicitly authorized bridge attachment for a selected Git project
uses [bridge configuration](configure-bridge-repos.md). A missing bridge is
valid; a configured bridge fails closed on drift.

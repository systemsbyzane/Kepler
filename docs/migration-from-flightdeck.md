# Migration from Flightdeck

Flightdeck becomes Kepler through repository history preservation, not a copied repository. The plugin ID, skill namespace, generated template, command, state paths, documentation, and repository links change from `flightdeck` to `kepler`.

This is a clean break: old plugin IDs and commands are not compatibility
aliases. Mission, Operation, workload-folder, clone-root, and mandatory-bridge
control planes remain removed. Snapshot the old control project, install
Kepler separately, create a new Kepler control project, select the same
existing saved Codex projects by live opaque ID and exact path, confirm a new
ArchitectureMap, and run Doctor. Do not scan a repositories root, import
legacy task/workflow state, or copy transcripts. The preserved old project is
the rollback path; selected projects are never rewritten by migration.

# Migration from Flightdeck

Flightdeck becomes Kepler through repository history preservation, not a copied repository. The plugin ID, skill namespace, generated template, command, state paths, documentation, and repository links change from `flightdeck` to `kepler`.

This is a clean break: old plugin IDs and commands are not compatibility aliases. Mission and Operation control planes remain removed. Snapshot the old control project, install Kepler separately, create a new Kepler control project, reconnect the same repositories through read-only discovery and exact-path verification, confirm a new ArchitectureMap, and run Doctor. Do not import legacy task/workflow state or transcripts. The preserved old project is the rollback path; connected repositories are never rewritten by migration.

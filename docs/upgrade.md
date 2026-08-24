# Upgrade

Kepler v1.0.0 is the first supported Kepler data format. Kepler v1.1.0 changes
new control projects to project-first setup. There is no in-place
control-project schema migration from the pre-Mission Flightdeck baseline:
that source has task/workflow state rather than Kepler's ArchitectureMap,
Plan, ContextPack, WorkerResult, and memory contracts. Treating those as
equivalent would recreate the removed lifecycle.

Plugin upgrade and control-project migration are separate authorization
boundaries. The plugin upgrade skill plans and verifies a same-identity Kepler
reinstall without running setup or changing a control project. Before any
future control-project migration, snapshot the complete control project,
validate the exact source and target versions, require a versioned idempotent
migrator, run Doctor and contract validation afterward, and keep the snapshot
until acceptance. Unsupported sources, downgrades, destructive rewrites, and
connected-repository mutations must fail closed.

For the Flightdeck-to-Kepler transition, create a new Kepler control project,
reconnect existing repositories by verified exact path, confirm a new
ArchitectureMap, and retain the old project as the rollback snapshot. Do not
import legacy tasks or transcripts. Rollback means reopening the preserved
project with its previous plugin; it never rewrites connected repositories.

# ADR 0001: Kepler v1 is a redesign

Status: Accepted

## Context

The selected history baseline removes Mission and Operation coordination
layers while retaining exact-path routing, worktree execution, verified
dispatch receipts, and receipt-and-stop behavior. A product rename alone
would preserve the wrong abstraction and would not solve repeated planning,
context loss between workers, or the lack of compact cross-worker handoffs.

## Decision

Kepler v1 is a clean-break redesign built on that safety baseline. Its durable
state is limited to a user-confirmed ArchitectureMap, lightweight revisioned
Plans, budgeted ContextPacks, validated WorkerResults, dispatch receipts, and
typed scoped memory. One Sol control task plans, dispatches, ingests status, and
coordinates the next wave; Terra workers execute in their owning Codex
projects. No compatibility alias is provided for the old plugin ID or command.

The Plan stores agreement, dependency order, readiness, and evidence. It is
not a scheduler, event bus, supervisor, or renamed Mission/Operation model.
Connected repositories remain in place and workers retain normal Codex
capability. Planning cannot mutate them; dispatch requires an exact Plan
revision and exact verified project path.

Ordinary setup begins from the Kepler control project and selects existing
saved Codex projects from the live project list. ArchitectureMap domains
replace workload directories, clone roots, and pseudo-projects. A bridge is an
optional advanced attachment, not a setup or dispatch prerequisite.

The installed Codex task surface supports explicit runtime selection. Sol is
mechanically requested as `gpt-5.6-sol` for the control task and Terra as
`gpt-5.6-terra` for repository workers. Dispatch receipts record requested and
effective model, reasoning, control-task ownership, and before/after worker
project association; a mismatch is a failed runtime acceptance check.
Natural language supplies objectives and Plan refinements, while `/kepler`
commands own setup, persistence, dispatch, review, status, and Doctor actions.
An optional Herdr attachment may resume the same verified Codex worker in a
terminal workspace. It does not replace app-server identity, prompt delivery,
DispatchReceipts, or WorkerResults. Cleanup is explicit and receipt-scoped.

## Consequences

- Historical lifecycle state is not imported into Kepler v1.
- Existing control projects are snapshotted and preserved; v1 setup creates a
  new control project and reconnects repositories by verified path.
- Plugin upgrade and control-project migration are separate authorization
  boundaries.
- Installed-plugin dispatch and upgrade acceptance require fresh Codex tasks;
  source validators cannot substitute for that evidence.
- Herdr task-resume compatibility and cleanup require installed, inside-Herdr
  acceptance; local fakes prove only the adapter contract.
- The generated control project contains no default development, charts,
  patching, research, environments, or compliance workload directories.

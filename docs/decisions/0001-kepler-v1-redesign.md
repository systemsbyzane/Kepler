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
typed scoped memory. Sol plans, Terra dispatches, and ordinary Codex tasks
execute. No compatibility alias is provided for the old plugin ID or command.

The Plan stores agreement, dependency order, readiness, and evidence. It is
not a scheduler, event bus, supervisor, or renamed Mission/Operation model.
Connected repositories remain in place and workers retain normal Codex
capability. Planning cannot mutate them; dispatch requires an exact Plan
revision and exact verified project path.

## Consequences

- Historical lifecycle state is not imported into Kepler v1.
- Existing control projects are snapshotted and preserved; v1 setup creates a
  new control project and reconnects repositories by verified path.
- Plugin upgrade and control-project migration are separate authorization
  boundaries.
- Installed-plugin dispatch and upgrade acceptance require fresh Codex tasks;
  source validators cannot substitute for that evidence.

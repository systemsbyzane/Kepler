# Kepler coordination layer

## Purpose

Kepler is a control room around ordinary Codex projects and tasks. It stores
compact coordination state and references; it does not copy repositories,
proxy workers, synchronize transcripts, or require a background runtime.

## Durable model

1. `hub/architecture-map.yaml` records user-confirmed workspace, project,
   repository, domain, path, and relationship topology.
2. `hub/plans/` records the agreed objective, constraints, exact revision,
   dependency order, readiness, receipts, results, and evidence references.
3. `hub/context-packs/` records small budgeted starting context for workers.
4. `hub/dispatch-receipts/` links ready Plan units to exact Codex projects and
   normal worker tasks.
5. `hub/worker-results/` records compact observed results and handoffs without
   copying transcripts.
6. `hub/memory/` stores sourced, typed, scoped, supersedable knowledge rather
   than chat history.

This is not a generalized lifecycle engine. Readiness is a deterministic
calculation over Plan dependencies and validated WorkerResults.

## Responsibility boundaries

- Sol creates and revises Plans. Planning may inspect evidence and control-room
  state, but it cannot mutate connected repositories or dispatch workers.
- Terra dispatches only ready units from one explicit Plan revision. It
  verifies exact project/path identity, creates or resumes normal Codex tasks,
  records receipts, returns them, and stops without monitoring.
- Workers remain directly accessible, fully capable Codex tasks. A ContextPack
  is initial relevant context, never a capability or inspection boundary.
- Kepler status is derived from structured Plan, receipt, and result state. It
  never infers completion by replaying a worker transcript.

## Failure behavior

Unknown topology, an unconfirmed ArchitectureMap, stale Plan revision,
waiting unit, identity mismatch, missing bridge handoff, or ContextPack budget
overrun fails closed. Kepler reports the exact mismatch and does not guess a
target, pick a newer revision, or silently perform owner work in the control
project.

Commits, remote writes, publication, deployment, shared-environment mutation,
external communication, compliance submission, risk acceptance, and closure
remain explicit approval gates.

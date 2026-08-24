# Kepler control-project instructions

This project stores coordination state for existing saved Codex projects. It is
not a source monorepo and does not own or contain their repositories.

## Explicit workflow

- `/kepler setup` lists saved Codex projects, lets the user select exact
  project IDs and paths, proposes an ArchitectureMap, and persists it only
  after explicit confirmation.
- `/kepler plan` uses Sol on `gpt-5.6-sol`. Sol may inspect selected projects
  read-only while planning. It may write Plan, ContextPack, and scoped memory
  artifacts here, but must not edit a selected project or dispatch work.
- `/kepler review` creates its review-only Plan in the current task when that
  task is already verified as Sol with high reasoning. A new review Plan or
  revision does not create another control-project task.
- `/kepler dispatch` stays in the current Sol control task and directly creates
  or resumes exact Terra workers on `gpt-5.6-terra` in their owning saved
  projects. It never creates an intermediary control-project dispatcher task.
  Every new implementation, review, research, or synthesis worker must
  use the permission-preserving Kepler bootstrap bound to the owning opaque
  project ID and final-task verification; direct prompted task creation is
  invalid. Before and after project-preserving prompt delivery, require both
  app-server and live-list project identity plus the Local or Worktree path to
  match the verified target. Collaboration-agent spawn, delegation, or
  resume is invalid for repository workers. The control task records requested
  and effective runtime, configuration, and association evidence, returns the
  receipt, and ends the dispatch turn without monitoring.
- `/kepler status` may read only the final response of a dispatched task,
  validate and idempotently ingest its exact WorkerResult, and then report
  structured state. It does not read progress, synchronize transcripts, or
  create a planner. `/kepler doctor` remains read-only.

Natural language supplies objectives and refinements. It never substitutes for
an explicit `/kepler` state-changing command.

## Projects, context, and bridges

Select only projects returned by the live Codex project list. Preserve each
opaque runtime project ID separately from its logical Kepler key and require
an exact normalized path match. Never scan a repository root, clone, move,
import, or edit selected projects during ordinary setup.

ArchitectureMap domains replace workload folders and pseudo-projects.
ContextPacks are useful initial context, never an exclusive boundary. Workers
remain normal, directly accessible Codex tasks and may follow repository
evidence beyond the initial paths.

Each worker receives the serialized ContextPack once. Do not repeat the Plan,
ArchitectureMap, objective, findings, or constraints in parallel prose. Reuse
observed evidence unless state may have changed, and return only a compact
structured WorkerResult under its declared budget.

Bridges are optional advanced configuration. Ordinary setup and dispatch work
without one. If a bridge is configured for a workspace, validate it strictly
and fail closed on drift.

## Results and approval boundaries

Request a structured WorkerResult at completion or a material blocker. Ingest
only relevant changes, discoveries, decisions, validation, blockers, handoffs,
and artifact references. Do not copy transcripts into this project.

Before Plan revision, review synthesis, or remediation planning, ingest every
available completed WorkerResult and pass only result paths and unresolved
decisions downstream. Artifact token estimates are not model-runtime telemetry;
report actual runtime tokens as unavailable unless trustworthy runtime evidence
is supplied.

Implementation requests may authorize edits and local checks in the exact
selected project. Commits, pushes, pull requests or comments, publication,
deployment, shared-environment mutation, external communication, compliance
submission, risk acceptance, and closure claims remain explicit gates.

Never store credentials, private keys, controlled evidence, or sensitive
customer material in Kepler state, prompts, reports, tests, or Git history.

# Control-task dispatch contract

The current verified Sol control task is the bounded dispatcher. It receives an
approved Plan ID and exact revision, one or more ready units, and their compiled
ContextPacks. It never creates an intermediary control-project dispatcher task,
re-plans during dispatch, or implements selected-project work.

## Allowed before dispatch

- the confirmed ArchitectureMap and exact Plan revision;
- the compiled ContextPack for each ready unit;
- control-project policy, selected-project registry, and optional bridge metadata;
- the read-only route plan;
- live saved-project state needed to verify an exact normalized path;
- recent task IDs, titles, modes, and state needed to find an exact matching
  worker to resume.

## Prohibited before dispatch

- target code or artifact analysis beyond exact identity verification;
- live environment inspection;
- project-specific scripts or implementation;
- changing the Plan or choosing a newer revision;
- monitoring a worker after receipt.

Use the exact verified runtime project ID for every worker. Create every
selected independent ready unit in one dispatch phase with the unit's requested
model and thinking level, and record both requested and effective values. The
worker prompt must include the serialized ContextPack exactly once, its
full-capability instruction, and the requirement to return a WorkerResult at
completion or a material blocker. Use only a minimal wrapper; do not repeat the
Plan, ArchitectureMap, objective, findings, references, or constraints outside
the ContextPack. Record only a verified task receipt with
`bin/kepler dispatch record`,
then return the receipts and end the dispatch turn without monitoring. Workers
remain ordinary Codex tasks in their owning saved projects and keep the user's
effective configuration.

## Control-task and project-association invariant

The task that owns the Plan also performs dispatch, records receipts, ingests
status, and coordinates the next wave. Do not create, fork, delegate to, or
resume another control-project task for dispatch. Model-role separation never
authorizes task separation here.

For a preserved Hub that predates
`kepler.command.control-task-dispatch.v1`, treat a route's legacy
`dispatcher_runtime` as the requested Terra worker runtime. Do not treat the
field name as permission to create a dispatcher task, and do not migrate the
Hub during dispatch.

Refresh the live project and task lists before prompt delivery. In Herdr, the
live project source is `list_cli_projects`; desktop-only project IDs are invalid.
Require the
worker's live `projectId` to equal the selected owning runtime project ID and
its exact Local or Worktree path to match the verified route. Continue an
existing worker only with the project-preserving Codex task-message surface.
Never use collaboration-agent spawn, delegation, or resume for a repository
worker, because those surfaces can reassign the task to the control project.
Before and immediately after any non-Herdr prompt delivery or continuation, call
`verify_worker_task` with `expected_runtime_project_id` set to the owning ID;
use `require_empty: true` only for the pre-prompt check and `false` for the
post-delivery or existing-task checks. Recheck the same ID and path in the live
lists. If either source drifts, fail closed, report the observed association,
and do not record a DispatchReceipt.

## Configuration-preserving local creation

Every new worker, including implementation, review, research, and synthesis,
must begin with Kepler's `bootstrap_worker_task`. Never create a prompted worker
with the desktop `create_thread` surface: it cannot attest the caller's complete
effective permission configuration and may silently select a managed
workspace-write, network-disabled default. Do not treat read-only work as an
exception; worker authorization and runtime sandbox configuration are separate
contracts.

Call `bootstrap_worker_task` with the owning opaque runtime project ID, exact
saved-project path, title, model, and thinking level. Omit `permission_profile`
to inherit the effective global configuration, or pass only the explicitly
selected named profile. Require the `kepler.worker-task-bootstrap/v1` receipt,
matching `expectedRuntimeProjectId` and `actualRuntimeProjectId`, and exact
model, thinking, configuration mode, approval policy, sandbox or permission
profile, and empty task state.

For Local mode, the bootstrap task is the final worker. For Worktree mode, hand
off that empty task to a local Worktree and use the destination task returned by
the handoff. In both modes, call `verify_worker_task` on the exact final task and
path using the owning runtime project ID and bootstrap receipt's expected
configuration. Require matching expected and actual project IDs,
`kepler.worker-task-verification/v1`, `verified: true`, and `empty: true` before
sending any prompt. A mismatched model, reasoning level, path, approval policy,
sandbox, permission profile, or non-empty task is a dispatch failure.

Only after configuration and live project-association verification may the
control task send the complete worker prompt. Outside Herdr, after delivery call
`verify_worker_task` again with `require_empty: false` and require the same task
and project ID plus `empty: false` before recording. In Herdr, use the integrated
post-delivery association evidence returned by `deliver_herdr_worker_prompt`.
The
DispatchReceipt must identify `creation_method: kepler-bootstrap-worker-task`,
the bootstrap task, the final verified task, both evidence schema versions,
the expected and actual bootstrap project IDs, pre-prompt and post-delivery
verified project IDs, the post-delivery non-empty state, the effective
configuration, and that verification preceded the prompt. Never
infer configuration from the caller, project, Plan, or bootstrap source task;
copy it from the bootstrap and final verification results. A direct-create,
missing-attestation, or mismatched receipt must be rejected instead of recorded.
It must record `dispatch_execution: current-control-task`, no intermediary
dispatcher, the project-preserving prompt delivery method, and matching live
project-association evidence from before and after delivery. It must also copy
the exact ContextPack ID, estimated token count, and budget
from the compiled artifact so status can report artifact estimates without
misrepresenting them as runtime usage.

The bootstrap and verification tools cannot send a prompt, edit files, create a
Worktree, delete or archive tasks, or monitor a worker. In Herdr, only
`deliver_herdr_worker_prompt` may submit the worker prompt, and it may wait only
for bounded exact-delivery evidence. If a required tool is
unavailable or rejects the effective configuration, fail closed instead of
using another creation path.

Reject a waiting unit, a stale or ambiguous Plan revision, a target that does
not exactly match the confirmed ArchitectureMap, or a ContextPack over its
budget. Never silently select the latest revision after dispatch preparation.

Bridges are optional. When the route reports `not_configured`, dispatch
directly and let the worker read its normal project instructions. When a
workspace explicitly configures a bridge, require
`bridge_handoff.status: verified`, include the handoff unchanged, and fail
closed on a missing, stale, or drifting bridge. Never install a bridge as an
implicit dispatch step.

Dispatch uses only projects already selected from the refreshed live project
list during setup. Keep the stable logical key separate from the opaque runtime
ID and recheck the exact normalized path. Never register, open, clone, or
substitute a display-name match during dispatch.

Workers remain normal, directly accessible Codex tasks. Do not proxy user
steering, copy their transcripts, or infer completion from task state. Only a
validated WorkerResult advances Plan readiness.

## Optional Herdr attachment

When `HERDR_ENV=1`, Kepler exposes the same verified worker task as a Herdr
agent. This is attachment, not alternate dispatch: bootstrap and verify the
Codex task first, then call `attach_herdr_worker` with the final task ID, owning
project ID, exact Local or Worktree path, and effective configuration. The tool
creates one background tab inside the current control workspace, starts Codex with
explicit model, reasoning, and sandbox/approval or profile arguments followed
by `resume <final-task-id>`, verifies Herdr preserved the receipt-bound terminal
and exact launch command, and returns the preserved workspace plus owned tab,
pane, and agent identities. It must never create a separate worker workspace.
If Herdr also exposes a Codex session ID, it must match the task.

The attachment tool cannot send the ContextPack. After attachment, call
`deliver_herdr_worker_prompt`; it submits through `herdr agent prompt`, then
proves the exact prompt was persisted on the same CLI task, project ID, and
path. It returns without waiting for completion. Browser controls, the Codex
desktop app, collaboration tasks, and transcript scraping are prohibited
fallbacks. Record the attachment only when its resumed task ID and worker path
match the DispatchReceipt. Herdr lifecycle
states are display evidence only; they never complete a unit or replace a
WorkerResult. If Herdr is absent, the caller is outside Herdr, attachment
fails, or the receipt-bound terminal/task identity does not match, fail the requested Herdr
attachment without falling back to a new terminal-created worker.

For `/kepler status` in Herdr, call `collect_herdr_worker_result` only after the
agent is idle or done. It returns only the latest completed final response from
the exact task and rejects active, failed, interrupted, reassociated, or
mismatched workers. Validate and ingest that response as the WorkerResult; do
not read the terminal transcript or progress output.

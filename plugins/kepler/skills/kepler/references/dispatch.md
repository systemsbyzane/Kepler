# Terra dispatch contract

Terra is a bounded dispatcher. It receives an approved Plan ID and exact
revision, one or more ready units, and their compiled ContextPacks. It never
re-plans or implements.

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
worker prompt must include the ContextPack, its full-capability instruction,
and the requirement to return a WorkerResult at completion or a material
blocker. Record only a verified task receipt with `bin/kepler dispatch record`,
then return the receipts and stop without monitoring. Workers remain ordinary
Codex tasks and keep the user's or saved project's normal runtime.

## Configuration-preserving local creation

Every new worker, including implementation, review, research, and synthesis,
must begin with Kepler's `bootstrap_worker_task`. Never create a prompted worker
with the desktop `create_thread` surface: it cannot attest the caller's complete
effective permission configuration and may silently select a managed
workspace-write, network-disabled default. Do not treat read-only work as an
exception; worker authorization and runtime sandbox configuration are separate
contracts.

Call `bootstrap_worker_task` with the exact saved-project path, title, model,
and thinking level. Omit `permission_profile` to inherit the effective global
configuration, or pass only the explicitly selected named profile. Require the
`kepler.worker-task-bootstrap/v1` receipt and exact model, thinking,
configuration mode, approval policy, sandbox or permission profile, and empty
task state.

For Local mode, the bootstrap task is the final worker. For Worktree mode, hand
off that empty task to a local Worktree and use the destination task returned by
the handoff. In both modes, call `verify_worker_task` on the exact final task and
path using the bootstrap receipt's expected configuration. Require
`kepler.worker-task-verification/v1`, `verified: true`, and `empty: true` before
sending any prompt. A mismatched model, reasoning level, path, approval policy,
sandbox, permission profile, or non-empty task is a dispatch failure.

Only after verification may Terra send the complete worker prompt. The
DispatchReceipt must identify `creation_method: kepler-bootstrap-worker-task`,
the bootstrap task, the final verified task, both evidence schema versions,
the effective configuration, and that verification preceded the prompt. Never
infer configuration from the caller, project, Plan, or bootstrap source task;
copy it from the bootstrap and final verification results. A direct-create,
missing-attestation, or mismatched receipt must be rejected instead of recorded.

The bootstrap and verification tools cannot send a prompt, edit files, create a
Worktree, delete or archive tasks, or monitor a worker. If either tool is
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

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

Use the available Codex task or thread creation/resume capability against the
exact verified runtime project ID. Create every new Terra dispatcher with
`model: gpt-5.6-terra` and `thinking: high`; record both requested and
effective values. Create every selected independent ready
unit in one dispatch phase. The worker prompt must include the ContextPack,
its full-capability instruction, and the requirement to return a WorkerResult
at completion or a material blocker. A successful create/resume response is
the receipt. Record the task ID/link, runtime project ID, exact project path,
mode, and authorization boundary with `bin/kepler dispatch record`; then
return the receipts and stop without monitoring. Workers remain ordinary
Codex tasks and keep the user's or saved project's normal runtime.

## Configuration-preserving local creation

The desktop task-creation surface may omit the caller's named permission
profile or may silently select a task-specific default. Inspect its current
schema before creating a worker. When it cannot carry the complete effective
configuration, use Kepler's `bootstrap_worker_task` tool with the exact project
path, title, model, and thinking level. Omit `permission_profile` so the tool
reads and inherits the effective global config for that project path. This
supports both the current named-profile system and the global
`sandbox_mode`/`approval_policy` system. Continue only when the receipt reports
the same effective configuration.

The bootstrap creates one empty persistent Local task. Send the complete worker
prompt only after the profile receipt passes. If the selected Plan mode is
Worktree, hand off the empty task to a local Worktree first, then send the
prompt to the destination task. Never substitute a cloud environment or a
different approval, sandbox, or permission configuration. The task, handoff,
and prompt-send responses form
the dispatch receipt; return it and stop without reading or monitoring the
worker.

The bootstrap cannot send a prompt, edit files, create a Worktree, delete or
archive tasks, or monitor a worker. If it is unavailable or rejects the
effective configuration, fail closed instead of creating a task with weaker or
different permissions.

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

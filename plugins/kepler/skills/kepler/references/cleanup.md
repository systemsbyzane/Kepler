# Receipt-driven cleanup

Cleanup is an explicit terminal phase for worker resources owned by one exact
Plan revision. It is not status, monitoring, deployment closure, branch
deletion, or evidence deletion.

Before cleanup, run `/kepler status` and ingest every available WorkerResult.
`/kepler cleanup` runs `bin/kepler cleanup prepare PLAN_ID --revision N`, shows
the complete removal set, and stops. It must not close, archive, or remove
anything. Select a unit only
when it has terminal structured state, a recorded DispatchReceipt, and a strict
Kepler-owned Herdr attachment. The envelope is the complete cleanup authority;
do not discover adjacent tabs, tasks, worktrees, or branches by name.

Only after the user invokes `/kepler cleanup authorize` for that unchanged
preview, process every envelope with one authorization:

1. Call `cleanup_herdr_worker` with `authorized: true`, the exact task, project,
   path, mode, attachment, and requested Worktree action. Do not request a
   separate approval for each envelope.
2. Require Herdr to report the recorded agent in `idle` or `done` state. Treat
   `working`, `blocked`, `unknown`, missing, or mismatched as a stop condition.
3. Require app-server to return the same idle Codex task, owning project ID, and
   exact path before archiving it.
4. Close only the recorded Kepler-owned worker tab and archive only the
   recorded worker task. Preserve the current workspace, control tab, and
   control agent.
5. For a requested Worktree removal, require a registered non-primary checkout,
   empty Git status, and a worker HEAD already contained by the owning
   project's current HEAD. Preserve the branch. Any failed precondition leaves
   the Worktree in place.
6. Save the tool response unchanged, then record it with
   `bin/kepler cleanup record PLAN_ID --revision N --unit UNIT --receipt FILE`.

The cleanup tool must reject calls without the explicit authorization flag and
complete every preflight before its first mutation. A
partial external failure is reported as a blocker and is never represented as
a successful CleanupReceipt. Repeating cleanup is allowed only when the
recorded receipt is identical. The current Herdr workspace and control tab, Sol control task,
Plans, ContextPacks, DispatchReceipts, WorkerResults, memory, branches, and
repository history remain intact.

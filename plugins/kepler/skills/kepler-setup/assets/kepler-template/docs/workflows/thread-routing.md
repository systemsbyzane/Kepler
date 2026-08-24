# Saved-project routing

Kepler routes only to projects selected from the live Codex project list and
confirmed in the ArchitectureMap.

## Planning

Sol uses `gpt-5.6-sol` with high reasoning. It may inspect selected projects
read-only to identify domains, paths, dependencies, constraints, and success
criteria. It may write Plan and ContextPack state in the control project but
must not edit selected projects. The same Sol control task owns later exact
dispatch, status ingestion, review, and next-wave coordination.

Reuse the current task when it already has the required Sol runtime. This
includes a new review-only Plan and later Plan revisions. Create a separate Sol
task only when the user explicitly requests one or the current task cannot
satisfy the Sol runtime contract.

## Dispatch

1. Require an explicit `/kepler dispatch` command, Plan ID, and exact current
   revision.
2. Resolve workspace and domain from the confirmed ArchitectureMap.
3. Match both the opaque runtime project ID and exact normalized path against
   the selected-project registry.
4. Prepare a non-exclusive ContextPack containing only direct dependency-edge
   related work. Choose the smallest lead Kepler skill
   and currently applicable companions; do not preload speculative skills.
5. Keep dispatch in the current Sol control task. Do not create, fork,
   delegate to, or resume an intermediary control-project dispatcher task.
6. For every new Terra worker, use `bootstrap_worker_task` with the owning
   opaque runtime project ID and exact saved path. Require its expected and
   actual project IDs to match. Direct prompted task creation is prohibited for
   implementation, review, research, and synthesis alike.
7. For Worktree mode, hand off the empty bootstrap task. Verify the exact final
   Local or Worktree task and owning project ID with `verify_worker_task` before
   sending its prompt.
8. Refresh the live project and task lists. Require the worker's project ID to
   equal the owning saved project and its task path to equal the verified Local
   or Worktree path. Continue existing tasks only through the
   project-preserving Codex task-message surface; never use collaboration-agent
   spawn, delegation, or resume for repository workers.
9. Record only a receipt whose bootstrap and final verification evidence prove
   the effective model, reasoning, approval, sandbox or permission profile,
   final path, empty pre-prompt state, and control-task dispatch ownership.
10. Send the serialized ContextPack exactly once with a minimal result wrapper;
   do not repeat Plan or repository context in prose.
11. Recheck the exact task through `verify_worker_task` with
    `require_empty: false` and recheck the live owning project ID and task path
    immediately after prompt delivery or continuation. Project reassociation
    fails dispatch and produces no receipt.
12. Fail closed on missing or mismatched evidence. Do not poll, wait, monitor,
   copy transcripts, or read progress after the verified receipt.

Workers remain directly accessible and follow project evidence beyond initial
ContextPack paths when necessary. When new evidence crosses domains, read the
newly applicable skill before domain-specific mutation; doing so never expands
authorization.

## Optional bridges

A workspace without a bridge dispatches normally. If a workspace explicitly
configures one, validate its record and integrity before dispatch and fail
closed on missing or drifting state. Never install a bridge implicitly.

## Results

Only a validated WorkerResult advances Plan readiness. `/kepler status` reads
only a completed task's final response and idempotently ingests the exact
structured result; it never reads progress or creates a planner. Ingest relevant changes,
discoveries, decisions, failed attempts, validation, blockers, handoffs, and
artifact references. Do not synchronize the worker transcript.

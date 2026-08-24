# Saved-project routing

Kepler routes only to projects selected from the live Codex project list and
confirmed in the ArchitectureMap.

## Planning

Sol uses `gpt-5.6-sol` with high reasoning. It may inspect selected projects
read-only to identify domains, paths, dependencies, constraints, and success
criteria. It may write Plan and ContextPack state in the control project but
must not edit selected projects or dispatch workers.

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
4. Prepare a non-exclusive ContextPack. Choose the smallest lead Kepler skill
   and currently applicable companions; do not preload speculative skills.
5. Create or resume Terra with `gpt-5.6-terra` and high reasoning.
6. For every new worker, Terra uses `bootstrap_worker_task` at the exact saved
   path. Direct prompted task creation is prohibited for implementation,
   review, research, and synthesis alike.
7. For Worktree mode, hand off the empty bootstrap task. Verify the exact final
   Local or Worktree task with `verify_worker_task` before sending its prompt.
8. Record only a receipt whose bootstrap and final verification evidence prove
   the effective model, reasoning, approval, sandbox or permission profile,
   final path, and empty pre-prompt state.
9. Fail closed on missing or mismatched evidence. Do not poll, wait, monitor,
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

Only a validated WorkerResult advances Plan readiness. Ingest relevant changes,
discoveries, decisions, failed attempts, validation, blockers, handoffs, and
artifact references. Do not synchronize the worker transcript.

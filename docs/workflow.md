# Workflow

1. `/kepler plan` asks Sol to inspect relevant evidence and create or revise a durable Plan. This is implementation-read-only.
2. Refine constraints in ordinary conversation; every material revision increments the Plan revision.
3. `/kepler dispatch` stays in the current Sol control task, identifies that revision, compiles ContextPacks for ready units, and directly verifies and launches exact Terra worker tasks in their owning projects.
4. The control task returns receipts and ends the dispatch turn without monitoring. Open workers directly whenever useful.
5. Workers return validated WorkerResults at completion or a material blocker.
6. `/kepler status` derives state and newly ready units from the Plan, receipts, and results.
7. Repeat dispatch until required evidence is complete.
8. `/kepler cleanup` closes and archives only receipt-owned terminal workers and safely removes already-merged Worktrees while preserving their branches and all structured evidence.

No command replays full transcripts or silently changes a Plan revision.
When the control task runs inside Herdr, each verified Codex worker may be
attached to an owned Herdr workspace before prompt delivery. This changes only
where the same task is visible, not routing, status, dependencies, or results.

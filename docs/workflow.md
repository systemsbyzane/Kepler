# Workflow

1. `/kepler plan` asks Sol to inspect relevant evidence and create or revise a durable Plan. This is implementation-read-only.
2. Refine constraints in ordinary conversation; every material revision increments the Plan revision.
3. `/kepler dispatch` identifies that revision, compiles ContextPacks for ready units, and asks Terra to verify and launch exact worker tasks.
4. Terra returns receipts and stops. Open workers directly whenever useful.
5. Workers return validated WorkerResults at completion or a material blocker.
6. `/kepler status` derives state and newly ready units from the Plan, receipts, and results.
7. Repeat dispatch until required evidence is complete.

No command replays full transcripts or silently changes a Plan revision.

# Saved-project routing

Kepler routes only to projects selected from the live Codex project list and
confirmed in the ArchitectureMap.

## Planning

Sol uses `gpt-5.6-sol` with high reasoning. It may inspect selected projects
read-only to identify domains, paths, dependencies, constraints, and success
criteria. It may write Plan and ContextPack state in the control project but
must not edit selected projects or dispatch workers.

## Dispatch

1. Require an explicit `/kepler dispatch` command, Plan ID, and exact current
   revision.
2. Resolve workspace and domain from the confirmed ArchitectureMap.
3. Match both the opaque runtime project ID and exact normalized path against
   the selected-project registry.
4. Prepare a non-exclusive ContextPack. Choose the smallest lead Kepler skill
   and currently applicable companions; do not preload speculative skills.
5. Create or resume Terra with `gpt-5.6-terra` and high reasoning.
6. Terra creates or resumes the ordinary worker in the exact project, records
   requested/effective runtime values, returns the receipt, and stops.
7. Do not poll, wait, monitor, copy transcripts, or read progress.

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

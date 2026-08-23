# Plan contract

A `kepler.dev/v1` Plan has a stable ID, monotonically increasing revision, objective, constraints, small state, and domain/path-targeted units. Units declare dependencies, ContextPack references, versioned DispatchReceipts, WorkerResults, and validation evidence.

Readiness is deterministic: a planned unit becomes ready only when all dependencies are completed. Every revision records a visible change summary and validates unit workspace, domain, and paths against the confirmed ArchitectureMap. Status exposes each unit's dependencies, worker task/link, receipt, blockers, validation, result, and newly ready units without inspecting transcripts. Stale revisions, unknown dependencies, cycles, duplicate IDs, and invalid states are rejected.

Cancellation is an explicit Plan revision. Execution-bound unit status,
receipts, and results carry forward across revisions, and those units cannot be
silently changed or removed. A blocked or failed unit is retried only through
a higher revision with `retry: true`; the change summary records the retry and
dispatch never retries implicitly. A WorkerResult remains valid against the
exact revision recorded in its unit's DispatchReceipt even if Sol has since
revised other Plan units. Plan is agreement and status, not an autonomous
scheduler or generalized lifecycle engine.

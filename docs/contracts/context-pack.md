# ContextPack contract

A ContextPack is a small auditable starting context for one Plan unit. It contains exact scope identity, objective, relevant architecture, sourced facts, applicable prior attempts, constraints, references, success criteria, and upstream handoffs.

Compilation deduplicates context, includes only dependency-targeted handoffs from upstream WorkerResults, estimates tokens, enforces a configurable budget, records why memory was included, and fails closed on unknown topology. Telemetry distinguishes memory candidates, selections, rejections, and estimated tokens from actual provider accounting. Every pack states that paths are initial context rather than an exclusive boundary and requests a WorkerResult.

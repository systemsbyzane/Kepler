# Kepler workflow

Use `/kepler plan` to create or revise the current durable Plan without implementation mutation. Use `/kepler dispatch` to compile ContextPacks and dispatch only ready units from the exact displayed revision. Terra returns task receipts and stops.

Workers are ordinary Codex tasks. The supplied paths are initial relevant context, never an exclusive boundary. Workers return compact WorkerResults rather than transcripts. `/kepler status` derives dependencies, validation, blockers, and newly ready units from structured state. `/kepler doctor` remains read-only.

Generated state lives under `hub/plans`, `hub/context-packs`, `hub/worker-results`, `hub/dispatch-receipts`, and `hub/memory`. Connected repositories are never copied into this control project.

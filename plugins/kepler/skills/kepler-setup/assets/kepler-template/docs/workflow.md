# Kepler workflow

Use `/kepler plan` to create or revise the current durable Plan without implementation mutation. Use `/kepler dispatch` in that same control task to compile ContextPacks and directly dispatch only ready Terra workers from the exact displayed revision into their owning projects. The control task returns receipts and ends the dispatch turn without monitoring.

Workers are ordinary Codex tasks. The supplied paths are initial relevant context, never an exclusive boundary. Workers return compact WorkerResults rather than transcripts. `/kepler status` derives dependencies, validation, blockers, and newly ready units from structured state. `/kepler doctor` remains read-only.

Inside Herdr, each worker runs in its own receipt-owned tab inside the current
control workspace. `/kepler cleanup` previews the exact worker tabs, tasks, and
optional safe Worktrees. `/kepler cleanup authorize` applies that unchanged set
once while preserving the control workspace, control agent, and branches.

Generated state lives under `hub/plans`, `hub/context-packs`, `hub/worker-results`, `hub/dispatch-receipts`, and `hub/memory`. Connected repositories are never copied into this control project.

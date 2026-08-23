# Architecture

Kepler runs inside Codex and coordinates normal Codex projects. A `Kepler-<company>` control project holds references and structured coordination state; application, platform, and other monorepos remain independent projects in their existing locations.

The routing model is `workspace → Codex project → repository → domain → path → dependency`. Discovery proposes an ArchitectureMap; the user confirms it before dispatch.

Sol owns system reasoning and Plan revisions. Terra owns exact-target verification and one-shot dispatch. Workers own implementation and may inspect any repository evidence necessary. Kepler owns the ArchitectureMap, Plans, ContextPacks, WorkerResults, receipts, memory, and system status.

Release invariants: planning does not mutate connected repositories; dispatch is explicit and revision-pinned; unresolved identities fail closed; workers remain fully capable; transcripts are not synchronized; memory stores sourced knowledge rather than chat; no hidden runtime or Mission/Operation lifecycle exists.

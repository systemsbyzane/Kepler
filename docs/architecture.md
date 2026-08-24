# Architecture

Kepler runs inside Codex and coordinates normal Codex projects. A `Kepler-<company>` control project holds references and structured coordination state; application, platform, and other monorepos remain independent projects in their existing locations.

The routing model is `workspace → saved Codex project → domain → path → dependency`. Live saved-project selection proposes an ArchitectureMap; the user confirms it before dispatch.

Sol runs on `gpt-5.6-sol`, owns system reasoning and Plan revisions, and may
inspect selected projects read-only. Terra runs on `gpt-5.6-terra`, owns
exact-target verification and one-shot dispatch, records requested/effective
runtime evidence, and stops at the receipt. Workers use their normal project
runtime, own implementation, and may inspect any project evidence necessary.
Kepler owns the ArchitectureMap, Plans, ContextPacks, WorkerResults, receipts,
memory, and system status.

Release invariants: planning does not mutate connected repositories; dispatch is explicit and revision-pinned; unresolved identities fail closed; workers remain fully capable; transcripts are not synchronized; memory stores sourced knowledge rather than chat; no hidden runtime or Mission/Operation lifecycle exists.

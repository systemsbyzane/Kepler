# Architecture

Kepler runs inside Codex and coordinates normal Codex projects. A `Kepler-<company>` control project holds references and structured coordination state; application, platform, and other monorepos remain independent projects in their existing locations.

The routing model is `workspace → saved Codex project → domain → path → dependency`. Live saved-project selection proposes an ArchitectureMap; the user confirms it before dispatch.

Sol runs on `gpt-5.6-sol`, owns system reasoning, Plan revisions, exact-target
dispatch, status ingestion, and next-wave coordination in one control task,
and may inspect selected projects read-only. Terra workers run on
`gpt-5.6-terra` in their exact owning projects, own implementation, and may
inspect any project evidence necessary. The control task records
requested/effective runtime and live project-association evidence, returns the
receipts, and ends the dispatch turn without monitoring.
Kepler owns the ArchitectureMap, Plans, ContextPacks, WorkerResults, receipts,
memory, and system status.

Herdr is an optional execution-view adapter. Kepler first creates and verifies
the exact app-server task and opaque project association, then Herdr resumes
that same task in a receipt-owned worker tab inside the current control
workspace. Herdr never becomes a second
worker identity or a source of unit completion. Previewed and explicitly
authorized cleanup closes the owned worker tab, preserves the control
workspace, archives the same Codex task, and removes only provably safe merged
Worktrees while retaining branches and structured evidence.

Release invariants: planning does not mutate connected repositories; dispatch
is explicit, revision-pinned, and performed by the current control task without
an intermediary dispatcher; worker project association is verified before and
after prompt delivery; unresolved identities fail closed; workers remain fully
capable; transcripts are not synchronized; memory stores sourced knowledge
rather than chat; no hidden runtime or Mission/Operation lifecycle exists.

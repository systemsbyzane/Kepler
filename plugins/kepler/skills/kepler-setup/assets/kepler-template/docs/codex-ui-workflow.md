# Codex project workflow

Open this control project and keep application, platform, documentation, and
other codebases as independent saved Codex projects.

`/kepler setup` lists those projects and records only selected opaque IDs plus
exact paths. It proposes ArchitectureMap workspaces and non-exclusive domains;
the user confirms them before planning or dispatch.

Sol may inspect selected projects read-only during `/kepler plan`. Terra uses
the exact verified target during `/kepler dispatch`. Every new worker starts as
an empty permission-preserving Local task, is handed off when Worktree mode is
required, and is verified again before its prompt. Direct prompted creation is
not a valid dispatch path. Terra returns the attested receipt and stops.
Workers remain directly accessible and may follow project evidence outside the
initial ContextPack paths.

Use `/kepler status` to read Plan, receipt, and WorkerResult state. Kepler does
not poll workers or synchronize their transcripts. Commits, remote writes,
deployments, publication, and shared-environment mutation remain explicit
approval boundaries.

# Codex project workflow

Open this control project and keep application, platform, documentation, and
other codebases as independent saved Codex projects.

`/kepler setup` lists those projects and records only selected opaque IDs plus
exact paths. It proposes ArchitectureMap workspaces and non-exclusive domains;
the user confirms them before planning or dispatch.

In Herdr, the saved-project source is the persistent Codex CLI registry, not the
desktop app. `list_cli_projects` produces the setup catalog and an explicitly
confirmed missing path may be added with `register_cli_project`. Desktop and CLI
opaque IDs are not interchangeable.

Sol may inspect selected projects read-only during `/kepler plan`; the same
control task performs `/kepler dispatch` without creating an intermediary
control-project task. Every new Terra worker starts as an empty
permission-preserving Local task bound to its owning opaque project ID, is
handed off when Worktree mode is required, and is verified again before its
prompt and after delivery. Existing workers are continued only
through the project-preserving task-message surface. Direct prompted creation
and collaboration-agent worker routing are invalid. The control task verifies
the app-server and live owning project ID plus task path before and after
delivery, returns the attested receipt, and ends the dispatch turn without monitoring.
Workers remain directly accessible and may follow project evidence outside the
initial ContextPack paths.

Herdr dispatch uses `attach_herdr_worker` followed by
`deliver_herdr_worker_prompt`. Each attachment is a new owned tab in the
current control workspace, never a separate workspace. The ContextPack is submitted to the exact resumed
agent through Herdr CLI and verified from the same persisted Codex task; no
browser or Codex desktop-app connection is involved. Herdr status collection
uses `collect_herdr_worker_result` and returns only the final response.

Use `/kepler cleanup` to preview the exact receipt-owned worker tabs, tasks, and
optional safe Worktrees. After reviewing it, `/kepler cleanup authorize`
applies that unchanged set once. Cleanup preserves the current workspace,
control tab, control agent, and every branch.

Use `/kepler status` to read Plan, receipt, and WorkerResult state. For a task
with a final response, status reads only that response and idempotently ingests
its exact structured WorkerResult. Kepler does not poll progress, synchronize
transcripts, or create a planner while collecting results. Commits, remote writes,
deployments, publication, and shared-environment mutation remain explicit
approval boundaries.

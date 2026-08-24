# Kepler control project

This project coordinates existing saved Codex projects. It does not contain,
clone, import, or manage their repositories.

## Start here

1. Run `/kepler setup`.
2. Select existing saved projects from the live Codex project list by exact
   path and opaque project ID.
3. Review and confirm the proposed ArchitectureMap domains and relationships.
4. Run `/kepler doctor`.
5. Use `/kepler plan`, refine the Plan in conversation, then explicitly run
   `/kepler dispatch` for the displayed revision.
6. Use `/kepler status` and structured WorkerResults for progression. Open
   ordinary workers directly whenever useful.

No repositories-root prompt or scan is part of setup. There are no generated
workload folders or pseudo-projects. Bridges are optional advanced
configuration and are not required for setup or dispatch.

## Runtime roles

- One Sol control task uses `gpt-5.6-sol` for planning, exact dispatch, status,
  review, and next-wave coordination without implementing repository work.
- Terra workers use `gpt-5.6-terra` in their exact owning saved projects and
  receive non-exclusive ContextPacks.
- Dispatch creates no intermediary control-project task, binds worker creation
  to the owning opaque project ID, verifies it through app-server and the live
  lists before and after delivery, returns receipts, and ends without monitoring.

Dispatch receipts record requested and effective runtime evidence. Worker
transcripts are never copied into this project.

## Deterministic helpers

```text
bin/kepler doctor --json
bin/kepler status
bin/kepler setup plan --project-catalog FILE --project-id ID --json
bin/kepler setup apply --project-catalog FILE --project-id ID --architecture-map FILE --confirm --json
bin/kepler route plan --workspace NAME --domain NAME --work-type TYPE --json
bin/kepler plan apply FILE [--expect-revision N]
bin/kepler dispatch prepare PLAN_ID --revision N
bin/kepler dispatch record PLAN_ID --revision N --unit ID --receipt FILE
bin/kepler result ingest FILE
bin/kepler review [PLAN_ID]
```

See [workflow](docs/workflow.md), [saved-project routing](docs/workflows/thread-routing.md),
[planning](docs/workflows/planning.md), and [advanced bridge configuration](docs/workflows/configure-bridge-repos.md).

---
name: kepler
description: Coordinate context-aware engineering work across existing Codex projects with ArchitectureMaps, revisioned Plans, focused ContextPacks, exact dispatch, WorkerResults, and scoped memory. Use for explicit /kepler commands, multi-project planning and status, exact worker dispatch, or Kepler control-project work. Do not use Kepler as an implementation runtime or background supervisor.
---

# Kepler

Requests to **set up Kepler** or **connect repositories** route to
`$kepler-setup`, which selects existing saved Codex projects by exact identity.

Kepler is the coordination and knowledge layer around ordinary Codex workers:

> Sol coordinates. Terra workers execute. Kepler remembers.

Locate the control project by walking upward to `kepler.yaml`, read its `AGENTS.md`, and use the latest confirmed `hub/architecture-map.yaml`. Repositories remain normal Codex projects; do not copy them into the control project.

## Commands

Interpret natural language as the engineering objective and `/kepler` as the requested coordination action:

- `/kepler setup`: use `$kepler-setup` to verify exact projects/paths, propose domains and relationships, obtain confirmation, persist the ArchitectureMap, and run Doctor. Discovery proposes; the user confirms.
- `/kepler plan`: use Sol and `$kepler-plan` to create or revise a `kepler.dev/v1` Plan. Planning may inspect evidence and write control-project Plan/ContextPack artifacts, but cannot edit connected repositories, dispatch, commit, push, open PRs, or deploy.
- `/kepler dispatch [unit]`: in the current verified Sol control task, read the
  current Plan ID/revision, run `bin/kepler dispatch prepare`, and directly
  create or resume every selected ready Terra worker. Never create an
  intermediary control-project dispatcher task, and never dispatch waiting,
  ambiguous, or stale-revision work.
- `/kepler status`: derive state from the Plan, receipts, and WorkerResults. For
  a dispatched task with a final response, read only that final response. In
  Herdr, call `collect_herdr_worker_result`; do not use a desktop-app, browser,
  or terminal transcript surface. Then
  validate and idempotently ingest its exact WorkerResult, then show
  dependencies, workers, validation, blockers, newly ready units, and artifact
  token estimates. Never replay progress or transcripts, and never create a
  planner while collecting results.
- `/kepler cleanup [unit]`: preview the exact receipt-owned worker tabs, tasks,
  and optional safe Worktrees that would be removed. This form is read-only.
- `/kepler cleanup authorize [unit]`: after the user reviews that preview,
  perform its exact cleanup with one authorization, preserve the current Herdr
  workspace and control agent, record CleanupReceipts, and preserve every
  branch. Refuse active, dirty, unmerged, unattested, or mismatched resources.
- `/kepler review`: use `$kepler-review` to create a review-only Plan in the current verified Sol task and lead with findings. Do not create another planner task merely because review uses a new Plan. Fixes require separate authorization.
- `/kepler doctor`: use `$kepler-doctor` for read-only integrity, exact-path, schema, architecture-map, and dispatch-capability checks.

Ordinary conversation may refine an active Plan. Every material change creates a monotonically higher revision with a visible change summary.

## Sol

Sol runs on `gpt-5.6-sol` with high reasoning and owns the complete control
loop: planning, exact dispatch, status ingestion, review, and next-unit
coordination. It identifies affected
workspaces/domains/paths, dependencies, safe concurrency, constraints, success
criteria, useful memory, and ContextPack inputs. It may inspect selected
projects read-only while planning and records requested/effective runtime
evidence. Sol never implements selected-project work. Phase separation does
not imply task separation: keep the control loop in this one task.

Before revising a Plan or preparing synthesis, ingest every available completed
WorkerResult. Give Sol the Plan ID/revision, result artifact paths, and unresolved
decisions; do not paste full findings, prior prompts, repository contents, or
worker transcripts into another planner prompt.

Reuse the current task for planning whenever its effective runtime is already
`gpt-5.6-sol` with high reasoning. This includes `/kepler review`, a new Plan,
and every Plan revision; role separation does not imply task separation. Do not
call `bootstrap_planner_task` solely for context isolation or a new planning
phase.

Start a separate Sol task only when the user explicitly requests one or the
current task's effective model or reasoning does not satisfy the Sol contract.
Pass the current effective model and reasoning to `bootstrap_planner_task`; set
`separate_task_requested` only for the explicit-user-request case. The tool
returns a no-op reuse receipt when the current task already satisfies the
contract. When it creates a task, require its effective runtime receipt, use the
exact control-project path and opaque runtime project ID, and omit
`permission_profile` to inherit the effective global config. Send the planning
objective only after the receipt's expected and actual project IDs match, then
keep all planning and Plan persistence in that task. The
bootstrap cannot send a prompt, edit files, dispatch workers, or monitor the
planner.

## Dispatch and Terra workers

The current Sol control task performs the bounded dispatch phase itself. It
receives approved ready units and their compiled ContextPacks, verifies the
exact Codex projects and paths, and creates every new Terra worker through
`bootstrap_worker_task`; this also applies to review and synthesis workers.
Direct prompted task creation is not a valid Kepler dispatch path. Do not
create, fork, delegate to, or resume an intermediary task in the control
project to perform dispatch.

Before continuing an existing worker, require the live task list to show the
exact owning runtime project ID and exact Local or Worktree path. Continue it
with the project-preserving Codex task-message surface. Never use collaboration
agent spawn, delegation, or resume for repository workers: those surfaces can
reassociate a worker with the control project. For a new worker, pass the owning
opaque runtime project ID to bootstrap and verify the empty final task with
`verify_worker_task`, then independently verify its live project association
before sending the prompt. Call the verifier again after delivery or
continuation with `require_empty: false`, and recheck the live project ID and
path. Any mismatch fails dispatch and must not produce a recorded receipt.

Every Terra worker runs on `gpt-5.6-terra` with high reasoning unless an
explicit approved unit contract selects another supported runtime. The control
task serializes each ContextPack exactly once with only a minimal task/result
wrapper; it does not also paste the Plan, ArchitectureMap, findings, or a
second prose version of the same objective. It records the verified receipt
with `bin/kepler dispatch record`, returns the receipts, and ends the dispatch
turn without monitoring. It must not re-plan during dispatch, invent a target,
implement, summarize a worker, or read worker progress.

When the control task is running inside Herdr (`HERDR_ENV=1`), use only the
CLI project registry from `list_cli_projects`; never reuse a desktop-only opaque
project ID. Require generated-Hub capability
`kepler.command.cli-herdr-dispatch.v1`; if it is absent, stop and propose the
managed Hub migration before dispatch because the preserved receipt schema
cannot attest CLI-native delivery. Attach each
verified empty worker task to a new owned tab inside the current control
workspace before prompt delivery by calling `attach_herdr_worker`. Never create
a worker workspace. Herdr is a visibility and lifecycle
surface for the same exact Codex task, never a replacement worker runtime.
Require the returned attachment to resume the same task ID at the same verified
path and record its explicit model, reasoning, and effective configuration
launch evidence. Call `deliver_herdr_worker_prompt` with the serialized ContextPack exactly
once and require its matching task, CLI project ID, path, prompt hash, and
attachment receipt. This CLI-native Herdr prompt is the post-delivery project
verification; do not call browser control, connect to the Codex app, or create
another task. Include the strict attachment and prompt-delivery evidence in the
DispatchReceipt. Outside Herdr, keep normal Codex task
dispatch unchanged; do not launch or control a Herdr session from outside one.

Read `references/dispatch.md` before dispatch. Preserve exact-project verification, the selected runtime/mode, and receipt-and-stop behavior.
Before relying on generated-Hub routing fields, check
`kepler.command.control-task-dispatch.v1`. When an older preserved Hub lacks
it, use the bundled dispatch reference and interpret its legacy
`dispatcher_runtime` only as the requested Terra worker runtime; it never
authorizes an intermediary dispatcher task. Plugin upgrade does not migrate
the Hub.

## Workers and results

Every worker prompt must include:

> These references and paths are initial relevant context, not an exclusive boundary. Follow repository evidence wherever necessary to complete the task correctly.

Workers remain directly accessible and fully capable. Request a `kepler.dev/v1` WorkerResult at completion or a material blocker. Validate and ingest it with `bin/kepler result ingest`; do not copy the transcript. Feed only relevant discoveries, decisions, failed attempts, handoffs, validation, and artifact references downstream.

Honor the ContextPack's WorkerResult budget. Return only the structured result,
reuse already observed evidence unless state may have changed, reference paths
and commands instead of reproducing file contents or long tool output, and do
not repeat the ContextPack in the result. ContextPack estimates describe initial
artifacts, not model-runtime usage; portable Kepler status must label actual
runtime tokens unavailable unless the runtime supplies trustworthy telemetry.
Before relying on generated-Hub token fields, check
`kepler.command.status-token-efficiency.v1`. When an older preserved Hub lacks
it, derive only ContextPack and WorkerResult artifact estimates from structured
files and keep runtime usage explicitly unavailable; plugin upgrade alone does
not authorize Hub migration.

## Cleanup

Cleanup is user-initiated and receipt-driven; status never performs it
silently. Read `references/cleanup.md` before either cleanup form. Bare
`/kepler cleanup` runs `bin/kepler cleanup prepare`, displays the complete exact
removal set, and stops without mutation. Only `/kepler cleanup authorize`
passes `authorized: true` to `cleanup_herdr_worker` for every unchanged envelope
from that preview, then records each returned receipt with
`bin/kepler cleanup record`. One explicit authorization covers the displayed
set; do not request another per-resource approval. Keep the current Herdr
workspace, its control tab, and the control task. Close only receipt-owned worker
tabs and archive their exact Codex workers. Remove a Worktree only when the cleanup envelope
requests it and the tool independently proves the checkout is inactive, clean,
registered, and already merged into the owning project's current checkout.
Never delete worker branches or structured Plan evidence.

## Memory

Store only sourced, typed, scoped, invalidatable knowledge. Prefer the narrowest SYSTEM, WORKSPACE, DOMAIN, or WORK scope. Preserve applicable failed attempts. Retrieve a small explainable set under the ContextPack budget; raw chat is not memory.

Commits, pushes, pull requests, publication, deployment, shared-environment mutation, external communication, compliance submission, risk acceptance, and closure remain explicit gates.

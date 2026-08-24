---
name: kepler
description: Coordinate context-aware engineering work across existing Codex projects with ArchitectureMaps, revisioned Plans, focused ContextPacks, exact dispatch, WorkerResults, and scoped memory. Use for explicit /kepler commands, multi-project planning and status, exact worker dispatch, or Kepler control-project work. Do not use Kepler as an implementation runtime or background supervisor.
---

# Kepler

Requests to **set up Kepler** or **connect repositories** route to
`$kepler-setup`, which selects existing saved Codex projects by exact identity.

Kepler is the coordination and knowledge layer around ordinary Codex workers:

> Sol plans. Terra dispatches. Codex executes. Kepler remembers.

Locate the control project by walking upward to `kepler.yaml`, read its `AGENTS.md`, and use the latest confirmed `hub/architecture-map.yaml`. Repositories remain normal Codex projects; do not copy them into the control project.

## Commands

Interpret natural language as the engineering objective and `/kepler` as the requested coordination action:

- `/kepler setup`: use `$kepler-setup` to verify exact projects/paths, propose domains and relationships, obtain confirmation, persist the ArchitectureMap, and run Doctor. Discovery proposes; the user confirms.
- `/kepler plan`: use Sol and `$kepler-plan` to create or revise a `kepler.dev/v1` Plan. Planning may inspect evidence and write control-project Plan/ContextPack artifacts, but cannot edit connected repositories, dispatch, commit, push, open PRs, or deploy.
- `/kepler dispatch [unit]`: read the current Plan ID/revision, run `bin/kepler dispatch prepare`, and dispatch every selected ready unit through Terra. Never dispatch waiting, ambiguous, or stale-revision work.
- `/kepler status`: derive state from the Plan, receipts, and WorkerResults. Show dependencies, workers, validation, blockers, and newly ready units; never replay transcripts.
- `/kepler review`: use `$kepler-review` to create a review-only Plan and lead with findings. Fixes require separate authorization.
- `/kepler doctor`: use `$kepler-doctor` for read-only integrity, exact-path, schema, architecture-map, and dispatch-capability checks.

Ordinary conversation may refine an active Plan. Every material change creates a monotonically higher revision with a visible change summary.

## Sol

Sol runs on `gpt-5.6-sol` with high reasoning. It identifies affected
workspaces/domains/paths, dependencies, safe concurrency, constraints, success
criteria, useful memory, and ContextPack inputs. It may inspect selected
projects read-only while planning and records requested/effective runtime
evidence. Sol is not the default implementation worker.

## Terra

Terra runs on `gpt-5.6-terra` with high reasoning. It receives one approved
ready unit and its compiled ContextPack, verifies the exact Codex project and
path, creates or resumes the normal worker, returns the receipt with requested
and effective runtime fields, records it with `bin/kepler dispatch record`, and
stops. Terra must not re-plan, invent a target, implement, summarize the
worker, or monitor it.

Read `references/dispatch.md` before dispatch. Preserve exact-project verification, the selected runtime/mode, and receipt-and-stop behavior.

## Workers and results

Every worker prompt must include:

> These references and paths are initial relevant context, not an exclusive boundary. Follow repository evidence wherever necessary to complete the task correctly.

Workers remain directly accessible and fully capable. Request a `kepler.dev/v1` WorkerResult at completion or a material blocker. Validate and ingest it with `bin/kepler result ingest`; do not copy the transcript. Feed only relevant discoveries, decisions, failed attempts, handoffs, validation, and artifact references downstream.

## Memory

Store only sourced, typed, scoped, invalidatable knowledge. Prefer the narrowest SYSTEM, WORKSPACE, DOMAIN, or WORK scope. Preserve applicable failed attempts. Retrieve a small explainable set under the ContextPack budget; raw chat is not memory.

Commits, pushes, pull requests, publication, deployment, shared-environment mutation, external communication, compliance submission, risk acceptance, and closure remain explicit gates.

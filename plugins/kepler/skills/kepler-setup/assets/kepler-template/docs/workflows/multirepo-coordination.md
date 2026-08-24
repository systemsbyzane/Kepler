# multi-repository application Multi-Repo Coordination

Use this workflow when one multi-repository application feature touches backend, frontend, and
optionally charts. The Kepler control project coordinates the feature; repo-scoped Codex tasks do
the implementation.

## Coordinator Contract

The hub thread owns:

- feature intent, non-goals, affected user flow, and security boundaries
- backend/frontend/charts work split
- choice of Local mode or Worktree mode for each repo thread
- ContextPacks, worker task IDs, and DispatchReceipts
- cross-project sequencing, approvals, and validated WorkerResult ingestion

Sol does not edit selected projects. The same Sol control task starts or
resumes the exact Terra workers directly in their owning projects, records
receipts, and ends the dispatch turn. `/kepler status` ingests validated WorkerResults;
worker transcripts are not synchronized.

## Thread Tool Flow

1. Run `/kepler setup` and select every already-saved project by opaque runtime
   ID and exact normalized path. If a project is absent, stop and use Codex's
   supported open-folder or registration action outside setup, refresh the live
   list, and select the exact match. Never accept a display name as identity.
2. Choose mode:
   - Use **Local** mode when the user says current branch, current checkout,
     continue existing work, or push commits to the current branches.
   - Use **Worktree** mode when the user wants isolation, parallel experiments,
     or a branch that should not touch the current checkout.
3. Search recent tasks in each exact selected project and resume only an
   objective match; otherwise bootstrap an empty permission-preserving task,
   hand it off for Worktree mode, and verify the final task before its prompt.
   Never directly create a prompted worker.
4. Dispatch only identified ready units from the persisted Plan revision.
5. Record logical project keys, runtime project IDs, child thread IDs, repo
   paths, branch expectations, bootstrap evidence, final configuration
   verification, and check status in the DispatchReceipts, then return
   immediately. Do not poll, wait, or read child progress after dispatch.

## Repo Split

Backend owns:

- API behavior, request validation, authorization, audit events, persistence,
  backend tests, and service-to-service boundaries

Frontend owns:

- UI state, user flows, API client calls, route guards, form validation,
  display behavior, frontend tests, and error handling

Charts owns:

- Helm values, templates, rendered Kubernetes manifests, image metadata,
  environment variables, RBAC, network policy, probes, resources, and rollout
  behavior

`remote-validation` owns:

- cluster inspection, logs, image rebuilds, deployment smoke checks, and
  Kubernetes validation that cannot be proven from the local checkout

For code authored on the local workstation and tested on `remote-validation`, follow:

- `docs/workflows/remote-validation.md`
- `docs/templates/development-vm-validation-handoff.md`
- `scripts/development-vm-preflight.sh`

## Required Guidance In Child Prompts

Every child-thread prompt must point at:

- `AGENTS.md` and any `AGENTS.override.md` in that repo
- `<hub-root>/docs/security/secure-code-preflight.md`
- `<hub-root>/docs/architecture/design-review.md`
- `<hub-root>/docs/templates/validation-evidence.md`
- `<hub-root>/docs/review/codex-review-readiness.md`
- `<hub-root>/docs/review/pr-evidence-packet.md`

For charts work, also include:

- `<hub-root>/docs/architecture/manifest-architecture.md`
- `<hub-root>/docs/review/charts-review-guidelines.md`

For backend work, also include:

- `<hub-root>/docs/review/backend-review-guidelines.md`

For frontend work, also include:

- `<hub-root>/docs/review/frontend-review-guidelines.md`

## Child Thread Prompt Requirements

Each repo thread must:

1. Read the repo instructions before editing.
2. Confirm current branch and dirty working tree state.
3. Restate the repo-owned portion of the feature.
4. Identify trust boundaries, authorization requirements, validation needs, and
   likely tests.
5. Make the smallest coherent implementation.
6. Run repo-appropriate checks or state exactly why they were skipped.
7. Capture validation evidence and residual risk.
8. Avoid commits, pushes, or PR actions unless explicitly requested.

## Completion Summary

Produce this only when the user later asks the Hub to read completed project
tasks or coordinate follow-up. Do not wait in the original dispatch turn.

The hub final summary for a coordinated feature should include:

- backend thread id, branch, files changed, checks, risks
- frontend thread id, branch, files changed, checks, risks
- charts thread id if used, branch, files changed, checks, risks
- remote build/rollout/cluster validation thread ids if used
- cross-repo compatibility notes
- remaining manual checks before GitHub `@codex review`

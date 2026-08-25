# Changelog

## 1.1.4 - Unreleased

- Retried only Herdr's structured `agent_pane_busy` response while a newly
  created worker tab's shell settles, reusing the exact tab, pane, agent name,
  and Codex resume arguments within a five-second bound.
- Kept every other Herdr attachment failure fail-closed with owned-tab rollback
  and no ContextPack delivery or dispatch receipt.

## 1.1.3 - Unreleased

- Preserved the requested worker model, reasoning level, path, and effective
  permissions when the Codex CLI resumes an empty worker for mandatory
  pre-prompt verification.
- Added a live-regression fixture that defaults resumed tasks to Sol unless
  Kepler explicitly reapplies the Terra runtime contract.

## 1.1.2 - Unreleased

- Added a persistent Codex CLI project catalog and explicitly confirmed CLI
  project registration for desktop-independent Herdr setup.
- Added exact ContextPack submission through `herdr agent prompt`, with
  task/project/path/terminal verification and duplicate-delivery protection.
- Added final-response-only WorkerResult collection from completed Herdr agents.
- Kept every Herdr worker in a distinct owned tab inside the current control
  workspace; dispatch no longer creates worker workspaces.
- Made cleanup preview-only until one explicit `cleanup authorize`, then close
  only receipt-owned worker tabs while preserving the control workspace.
- Prohibited browser and Codex desktop-app fallbacks in the Herdr dispatch path.

## 1.1.1 - Unreleased

- Kept planning, dispatch, status, and review in one Sol control task.
- Bound worker creation to the owning opaque runtime project ID and fail closed
  when app-server reports a different project after creation, handoff, prompt
  delivery, or continuation.
- Required DispatchReceipts to record actual project identity from bootstrap,
  pre-prompt verification, post-delivery verification, and the live task list.
- Reduced duplicate ContextPack and WorkerResult context.
- Added optional Herdr attachment for the same exact Codex worker task, keeping
  opaque project routing and structured status unchanged.
- Added receipt-driven cleanup that archives completed workers and removes only
  clean, inactive, already-merged Worktrees while preserving branches.

## 1.0.0 - Unreleased

- Renamed Flightdeck to Kepler across repository, plugin, skills, generated control project, contracts, and docs.
- Added confirmed ArchitectureMaps, revisioned Plans, budgeted ContextPacks, WorkerResults, exact dispatch receipts, and scoped typed memory.
- Added explicit `/kepler setup`, `plan`, `dispatch`, `status`, `review`, and `doctor` behavior.
- Removed the old operations product surface and retained the pre-Mission exact-path, worktree, receipt, and stop-after-dispatch safety foundation.
- Added install, setup, workflow, command, contract, memory, upgrade, troubleshooting, and migration guidance.

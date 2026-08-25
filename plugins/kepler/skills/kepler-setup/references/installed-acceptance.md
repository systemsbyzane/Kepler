# Installed plugin fresh-task acceptance

Run only after explicit authorization to install or change the plugin. Use a
clean `CODEX_HOME` profile and fresh tasks. Record each check as `passed`,
`failed`, or `blocked`; source and local harness results cannot substitute.

## Install

Verify the current CLI help, then exercise both documented paths:

```text
codex plugin marketplace add systemsbyzane/Kepler --ref main --json
codex plugin list --marketplace kepler-team --available --json
codex plugin add kepler@kepler-team --json
```

For local development, replace the Git source with the exact repository path.
Verify the installed enabled record and exact version, then start a fresh task.

## End-to-end workflow

1. Start a fresh Codex control task inside a named Herdr session and one
   `Kepler-Synthetic` control workspace. Require `HERDR_ENV=1`, record the
   session/workspace/task IDs, and call `list_cli_projects` without opening or
   connecting to the Codex desktop app. For two synthetic repository paths not
   yet present, explicitly confirm and call `register_cli_project`, then require
   both to appear with stable CLI opaque IDs in the refreshed list.
2. Run `/kepler setup`; select those two exact CLI projects. Desktop-only IDs
   must fail closed and must not be copied into the ArchitectureMap.
3. Confirm the ArchitectureMap and run `/kepler doctor`.
4. Prove there was no repository-root prompt or scan, no workload directories
   or pseudo-projects, no bridge requirement, and no selected-project mutation.
5. Run `/kepler plan` on Sol and persist revision 1. Refine the objective in
   ordinary conversation and persist revision 2 in the same Sol task. Create a
   review-only Plan and require the same-task reuse receipt rather than another
   control-project task.
6. Attempt revision-1 dispatch and require stale-revision rejection.
7. Capture the live control-project task list, then run `/kepler dispatch` for
   revision 2 in the same Sol control task. Require no new or resumed
   control-project dispatcher task. Require every new worker to use
   `bootstrap_worker_task` with the owning opaque runtime project ID, require
   its returned expected and actual project IDs to match, verify the exact final
   task with `verify_worker_task` before its prompt, and record requested/effective
   `gpt-5.6-terra`, reasoning, approval, sandbox or permission-profile, path,
   empty pre-prompt evidence, and exact ContextPack token accounting. Before
   prompt delivery, require the live worker `projectId` to equal the owning
   saved project ID and the task path to equal the verified Local or Worktree
   path. Call `deliver_herdr_worker_prompt` exactly once and require its prompt
   hash, task ID, CLI project ID, path, and Herdr attachment evidence. Browser
   control, a Codex desktop-app connection, collaboration-agent spawn,
   delegation, generic resume, or terminal transcript delivery fails
   acceptance. Require the delivery receipt's non-empty exact task and live
   project association in the DispatchReceipt. Require
   the serialized ContextPack exactly once; direct prompted creation or
   duplicated Plan/ContextPack prose fails acceptance.
   Between pre-prompt verification and prompt delivery, call
   `attach_herdr_worker`. Require one background workspace at the exact worker
   path, one Codex agent whose detected session ID equals the final task ID,
   explicit Terra model, high reasoning, and effective configuration launch
   arguments, and a strict owned attachment in the DispatchReceipt. If Herdr
   transiently reports structured `agent_pane_busy` while the root shell
   settles, require bounded retries to reuse the same tab, pane, agent name, and
   complete resume arguments. A separate task or
   desktop/app-controlled delivery fails acceptance.
8. Verify Sol used requested/effective `gpt-5.6-sol` evidence and performed
   read-only planning inspection only.
9. Open the ordinary worker directly. Verify its ContextPack contains
   provenance, only direct dependency-edge related work, the compact
   WorkerResult budget, and says initial context is not an exclusive boundary.
10. Return a structured WorkerResult, call `collect_herdr_worker_result`, ingest
    only its terminal `finalResponse`, run `/kepler status`, and
    dispatch the next newly ready unit. Repeat the same ingestion and require
    an unchanged idempotent result. Status must report ContextPack and
    WorkerResult artifact estimates, label runtime token usage unavailable, and
    create no planner task.
11. Repeat the exact objective to prove matching worker resume through the
    project-preserving task-message surface; use a distinct objective to prove
    create. Require the same owning project ID before and after both paths,
    current-control-task receipt-and-stop, and no monitoring.
12. Verify no worker transcript was copied or synchronized and that Herdr
    lifecycle state alone never advanced a unit.
13. Require every dispatched worker to appear as a distinct owned tab inside
    the original control workspace; a second worker workspace fails acceptance.
    After every selected unit has a terminal WorkerResult, run
    `bin/kepler cleanup prepare` from the exact Plan revision. Prove the preview
    performs no mutation and that `cleanup_herdr_worker` refuses a missing
    explicit authorization. Then authorize the unchanged set once. First prove
    a working or blocked worker is refused without mutation. Clean an idle
    attached worker and require only its exact owned Herdr tab to close, the
    same Codex task to become archived, and the control workspace/tab/task to
    remain. For a Worktree, prove dirty and unmerged states are refused; after
    it is clean and contained by the owning checkout HEAD, require checkout
    removal with the branch and all structured artifacts preserved. Record the
    exact CleanupReceipt and prove an identical record is idempotent.

The acceptance record must use schema `kepler.runtime-acceptance/v1` and include
plugin/version, candidate root, `control_project_path`, clean profile path,
selected logical keys, runtime project IDs, exact paths, Plan
revisions, control task ID, bootstrap and final task IDs, modes,
requested/effective model and
reasoning values, effective configuration attestations, receipts, WorkerResult
IDs, status transitions, artifact token estimates, before/after live task
project associations, Herdr session/workspace/tab/pane/agent identities,
CleanupReceipt IDs and outcomes, commands and exit codes, and before/after Git status.
Never record credentials or repository contents.

Any intermediary dispatcher task, collaboration-agent worker routing, changed
worker project association, missing exact identity, model evidence,
confirmation, stale-revision
rejection, permission-preserving bootstrap, final pre-prompt configuration
verification, direct-worker access, create/resume proof, WorkerResult
progression, same-task Herdr attachment, cleanup refusal/success evidence, or
no-monitoring proof blocks release.

## Plugin upgrade acceptance

Run this separately and only after explicit plugin-update authorization. Start
from an exact prior Kepler version in the clean profile and preserve a synthetic
control project plus selected synthetic project state.

1. Capture the prior installed version, control-project Doctor result, Git
   status for the control and selected projects, and ignored-state digest.
2. For a Git marketplace, run
   `codex plugin marketplace upgrade kepler-team --json`; a local marketplace
   does not use this refresh command.
3. Run `codex plugin add kepler@kepler-team --json` without removing the prior
   plugin and without running setup or bootstrap.
4. Verify installed version `1.1.4`, start a fresh task, and prove the target
   Kepler skills load.
5. Re-run the preservation checks and require unchanged control-project Git
   status, selected-project Git status, and ignored state plus a passing Doctor.

Record schema `kepler.upgrade-acceptance/v1`, exact prior/target/installed
versions, plugin ID, marketplace source type, approval, structured command
arguments and exit codes, fresh-task discovery, and these four passed checks:
`control_project_doctor`, `control_project_git_status`,
`selected_project_git_status`, and `ignored_state`.

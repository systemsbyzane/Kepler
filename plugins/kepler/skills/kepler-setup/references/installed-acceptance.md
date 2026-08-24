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

1. Create or open one `Kepler-Synthetic` control project and ensure two
   pre-existing saved Codex projects are visible in the live list.
2. Run `/kepler setup`; select those two exact projects.
3. Confirm the ArchitectureMap and run `/kepler doctor`.
4. Prove there was no repository-root prompt or scan, no workload directories
   or pseudo-projects, no bridge requirement, and no selected-project mutation.
5. Run `/kepler plan` on Sol and persist revision 1. Refine the objective in
   ordinary conversation and persist revision 2.
6. Attempt revision-1 dispatch and require stale-revision rejection.
7. Run `/kepler dispatch` for revision 2. Require every new worker to use
   `bootstrap_worker_task`, verify the exact final task with
   `verify_worker_task` before its prompt, and record requested/effective
   `gpt-5.6-terra`, reasoning, approval, sandbox or permission-profile, path,
   and empty pre-prompt evidence. Direct prompted creation fails acceptance.
8. Verify Sol used requested/effective `gpt-5.6-sol` evidence and performed
   read-only planning inspection only.
9. Open the ordinary worker directly. Verify its ContextPack contains
   provenance and says initial context is not an exclusive boundary.
10. Return a structured WorkerResult, ingest it, run `/kepler status`, and
    dispatch the next newly ready unit.
11. Repeat the exact objective to prove matching worker resume; use a distinct
    objective to prove create. Require receipt-and-stop with no monitoring.
12. Verify no worker transcript was copied or synchronized.

The acceptance record must use schema `kepler.runtime-acceptance/v1` and include
plugin/version, candidate root, `control_project_path`, clean profile path,
selected logical keys, runtime project IDs, exact paths, Plan
revisions, bootstrap and final task IDs, modes, requested/effective model and
reasoning values, effective configuration attestations, receipts, WorkerResult
IDs, status transitions, commands and exit codes, and before/after Git status.
Never record credentials or repository contents.

Any missing exact identity, model evidence, confirmation, stale-revision
rejection, permission-preserving bootstrap, final pre-prompt configuration
verification, direct-worker access, create/resume proof, WorkerResult
progression, or no-monitoring proof blocks release.

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
4. Verify installed version `1.1.0`, start a fresh task, and prove the target
   Kepler skills load.
5. Re-run the preservation checks and require unchanged control-project Git
   status, selected-project Git status, and ignored state plus a passing Doctor.

Record schema `kepler.upgrade-acceptance/v1`, exact prior/target/installed
versions, plugin ID, marketplace source type, approval, structured command
arguments and exit codes, fresh-task discovery, and these four passed checks:
`control_project_doctor`, `control_project_git_status`,
`selected_project_git_status`, and `ignored_state`.

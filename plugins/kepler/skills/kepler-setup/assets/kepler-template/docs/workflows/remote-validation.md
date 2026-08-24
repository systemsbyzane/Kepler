# Local To Remote Validation Validation

Use this workflow when multi-repository application code is authored on the local workstation but runtime
testing must happen on the `remote-validation` kind cluster.

## Ownership Split

Mac owns:

- source code edits
- Git branches, commits, pushes, diffs, and PR preparation
- repo checks that can run without the VM cluster
- final source-of-truth evidence for what code should be tested

`remote-validation` owns:

- rebuilding images from exact branch/SHA or an explicit patch bundle
- loading images into kind configured validation cluster
- Helm upgrades for `development-backend` and `development-frontend`
- pod health, logs, routes, and smoke checks
- validation evidence tied to the cluster

## Required saved Codex projects

Select the existing local projects that own the source and deployment manifests.

- `<existing-backend-project>`
- `<existing-frontend-project>`
- `<existing-charts-project>`

Add these remote `remote-validation` projects:

- `<remote-checkout>/backend`
- `<remote-checkout>/frontend`
- `<remote-checkout>/charts`
- `<remote-checkout>`

`/kepler setup` verifies selected projects using the live list, opaque runtime
IDs, and exact normalized paths. It does not clone, open, or register them. If
a required project is missing, add it through the supported Codex action,
refresh the list, and select the exact match. Use SSH-only validation as a
fallback only when remote task launch actually fails.

## Default Flow

1. Start in the Kepler control project with `/kepler plan`.
2. Run `bash scripts/development-vm-preflight.sh`.
3. Confirm the local branch/SHA for backend, frontend, and charts.
4. If a Local repository is dirty, choose one:
   - commit and push the branch
   - create an explicit patch bundle for remote-only validation
   - intentionally test existing VM dirty files as a scratch experiment
5. Create or continue Local repository threads for code work.
6. Create or continue `remote-validation` repo threads for image build and cluster
   rollout.
7. remote backend thread checks out the exact backend branch/SHA or applies the
   explicit patch bundle.
8. remote frontend thread checks out the exact frontend branch/SHA or applies the
   explicit patch bundle.
9. remote charts thread checks out the exact chart branch/SHA or prepares temporary
   Helm overrides.
10. remote validation thread confirms:
    - Docker is usable
    - `kind get clusters` includes `validation`
    - current context is `kind-validation`
    - configured validation namespace exists
    - Helm releases exist
11. Build backend and frontend images on `remote-validation`.
12. Tag images with branch/SHA-specific local tags.
13. Load images into kind configured validation cluster.
14. Helm upgrade the multi-repository application releases with those tags and
    `global.imagePullPolicy=IfNotPresent`.
15. Wait for rollout and capture pods, logs, deployed image refs, route checks,
    and residual risk.

## Do Not Guess

Before VM rollout, identify exactly which code is being tested:

- Git branch
- commit SHA
- dirty files or patch bundle path
- image tag
- Helm release
- namespace
- previous deployed image ref

If the remote repository branch does not match the local branch/SHA, stop and either pull
the branch, apply a patch bundle, or state that this is a scratch remote-only test.

## Prompt To Use

Use `docs/templates/development-vm-validation-handoff.md` when creating remote
remote build and validation threads from the hub.


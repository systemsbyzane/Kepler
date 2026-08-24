# CI/CD and delivery

Use `/kepler plan` for checks, pipelines, builds, releases, or delivery work.
Describe the objective in natural language after the command.

## Exact evidence

Identify the repository, provider, pipeline, run, candidate SHA, and delivery
environment. Correlate current provider evidence with the workflow definition
at that exact revision; the latest run and current checkout may differ.

Sol may inspect the selected project's pipeline source and provider evidence
read-only while preparing the Plan. Terra dispatches an approved unit and
returns the receipt without monitoring.

## Adaptive action

- Status and explanation are read-only.
- Diagnosis finds the first causal failure rather than listing downstream
  symptoms.
- A requested fix changes the smallest owning source surface and validates it.
- Delivery separates build, publish, promote, deploy, and verify.

Check permissions, secrets, untrusted inputs, dependencies, caches,
concurrency, artifact integrity, provenance, environment protection, failure
behavior, and rollback only as the risk requires.

Read-only inspection and local validation do not authorize rerun, cancel,
provider setting changes, publication, promotion, deployment, or environment
mutation. Each external action requires explicit authorization.

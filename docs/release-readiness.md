# Kepler release readiness

A release is ready only when every mandatory item below is evidenced.

## Product invariants

- `/kepler setup` starts in a `Kepler-<company>` control project and selects
  existing saved Codex projects by live opaque ID and exact normalized path.
- Setup never asks for or scans a repositories root; it does not clone, move,
  import, open, or edit selected projects. In Herdr, an exact user-confirmed
  path may create only a persistent Codex CLI project record.
- The generated template contains no development, charts, patching, research,
  environments, compliance, Mission, or Operation workload topology and no
  pseudo-projects or clone roots.
- ArchitectureMap workspaces/domains replace workload ownership.
- Bridges are absent by default and not required for setup or dispatch.
  Explicitly configured bridges fail closed on missing or drifting state.
- Sol uses requested/effective `gpt-5.6-sol` evidence and may inspect selected
  projects read-only while planning.
- The current Sol task dispatches the exact current Plan revision directly and
  creates no intermediary control-project task. Terra workers use
  requested/effective `gpt-5.6-terra` evidence in their owning projects.
- Every worker keeps the exact owning saved-project ID and Local or Worktree
  path before and after project-preserving prompt delivery; collaboration-agent
  routing is invalid.
- Workers are ordinary, directly accessible Codex tasks. ContextPacks are
  provenance-bearing initial context, never an exclusive boundary.
- WorkerResults, not transcripts or task-state inference, advance readiness.
- Herdr attachment resumes the same verified Codex CLI task in an owned worker
  tab inside the current control workspace, submits the
  ContextPack through that exact agent without desktop/browser controls, and
  collects only the final response; it never treats Herdr state as completion.
- Cleanup is preview-first, explicitly authorized once, receipt-owned,
  control-workspace-preserving, branch-preserving, and fail-closed for
  active, dirty, unmerged, missing, or mismatched resources.
- Natural language supplies objectives and Plan refinements. Setup, dispatch,
  review, status, and Doctor state changes use explicit `/kepler` commands.

## Local source gates

- plugin manifest and marketplace validation;
- every skill quick validator;
- all Ruby and Python tests;
- JSON, YAML, and JSON Schema parsing;
- fresh atomic setup generation and generated Doctor;
- no-workload-topology assertion;
- de-branding and setup-link validation;
- deterministic STIG round trip;
- local acceptance harness;
- semantic parity comparison and its functional probes;
- full diff review and final `git status`.

Local gates must distinguish observed runtime behavior from source assertions.
They cannot prove installed skill discovery, model selection, or task dispatch.
They also cannot prove that an app-server task resumes interactively inside a
live Herdr session or that live attachment cleanup reaches the intended session.

## Installed clean-profile gates

After explicit installation authorization, follow the setup skill's
`references/installed-acceptance.md` in a clean profile and fresh tasks.
Require verified public-Git and local-development installation commands, exact
plugin version, two selected existing projects, confirmed ArchitectureMap,
Doctor, Plan revision/refinement, stale revision rejection, Sol control-task and
Terra worker model evidence, no intermediary dispatcher, owning-project
preservation, create and resume receipts, direct worker access, structured
WorkerResult ingestion, next-unit readiness, no transcript sync, receipt-stop,
inside-Herdr attachment to the same task, safe cleanup refusal and success,
and before/after Git status.

A missing exact identity, model value, runtime receipt, or fresh-task result is
`blocked`, never inferred success.

## External decisions

- This source-available distribution intentionally has no license file.
- Plugin installation, cache mutation, commit, push, pull request, publication,
  deployment, shared-environment mutation, and archiving a legacy repository
  each retain their explicit authorization boundary.
- Record the owner's final disposition for the unrelated private
  `Kepler-legacy` repository; migration never modifies its contents.

Do not claim readiness while any local gate, installed runtime gate, or owner
decision remains unresolved.

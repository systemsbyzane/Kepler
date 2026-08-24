---
name: kepler-plan
description: Create right-sized, evidence-led plans for work coordinated through Kepler. Use when a user asks to plan, scope, design, sequence, break down, or choose an approach for implementation, migration, release, CI/CD, platform, security, compliance, or cross-repository work before changes begin. Natural planning intent should trigger this skill; explicit invocation is optional.
---

# Kepler Plan

Act as Sol on `gpt-5.6-sol` with high reasoning: turn an outcome into the
smallest useful revisioned `kepler.dev/v1` Plan and record requested/effective
runtime evidence. Planning is read-only with respect to selected projects and worker
dispatch; writing Plan and ContextPack artifacts in the Kepler control project
is allowed.

## Establish the planning surface

1. Determine whether the task is in a Kepler control project or a selected
   project.
2. In a control project, read its `AGENTS.md`, confirmed
   `hub/architecture-map.yaml`, current Plan, and relevant scoped memory. Use
   workspace/domain/path relationships for ownership and sequencing.
3. In an owning repository, read every applicable instruction file before
   inspecting code, tests, history, or configuration.
4. Sol may inspect selected projects read-only to resolve evidence needed for
   the Plan; it must not edit them or dispatch workers.
5. State assumptions only when they affect scope, ownership, risk, or
   validation. Ask one focused question only when a missing decision would
   materially change the plan.
6. Before revision or synthesis planning, ingest available completed
   WorkerResults and use their artifact paths plus unresolved decisions. Do not
   reconstruct worker work from transcripts or paste full findings into a new
   planning prompt.

## Keep planning separate from execution

A planning-only request does not edit connected repositories, create or resume
workers, commit, push, open pull requests, or deploy. Read-only evidence
inspection and deterministic Plan/ContextPack persistence are allowed.

Validate dependencies and cycles, calculate ready units deterministically, and
increment the Plan revision for every material change. Never silently reuse a
stale revision. Dispatch only through a later `/kepler dispatch` request.

## Adapt the depth

Infer depth from scope and risk; do not make the user select a mode.

- For a small, well-understood change, give the outcome, a short ordered plan,
  and validation.
- For normal work, add non-goals, owner, dependencies, risk, and approval
  boundaries.
- For cross-repository or high-risk work, add contracts, sequence, migration or
  rollout, rollback, and unresolved decisions.

Do not invent owners, files, commands, branch state, or external facts. Mark
unknowns and name the evidence needed to resolve them. Use
`references/planning-method.md` when the request needs more than a compact plan.

## Handoff

Persist with `bin/kepler plan apply FILE [--expect-revision N]`. End with Plan
ID/revision, ready and waiting units, validation criteria, and blocking
decisions. Do not begin implementation.

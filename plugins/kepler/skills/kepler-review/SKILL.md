---
name: kepler-review
description: Review changes and readiness through Kepler with findings-first, evidence-backed output. Use when a user asks to review a pull request, diff, branch, commit, working tree, architecture or implementation plan, release readiness, or a cross-repository change for correctness, security, regressions, compatibility, and missing validation. Natural review intent should trigger this skill; explicit invocation is optional.
---

# Kepler Review

Review the exact candidate surface and lead with actionable findings. In a
Kepler control project, represent cross-domain review as a review-only Plan
whose units cannot implement fixes. Do not fix findings unless the user
separately authorizes a new implementation Plan.

When the current control task already runs `gpt-5.6-sol` with high reasoning,
prepare and persist that review-only Plan in the same task. A new review target,
Plan ID, or revision is not a reason to bootstrap another planner task.

## Resolve the review target

1. Identify the artifact or Git comparison being reviewed and the question the
   review must answer. Do not silently substitute a different base, branch,
   commit, pull request, or working-tree diff.
2. In a Kepler control project, use the installed setup skill's
   `scripts/hub_compatibility.py` to check
   `kepler.document.change-review.v1` and, for repository-owned targets,
   `kepler.command.route-plan.v1`. Read `AGENTS.md` and
   `docs/review/change-review.md` only when available. When only the review
   document is missing, record the compatibility result and use this skill's
   bundled `references/review-method.md`; do not claim the Hub-local workflow
   was read. Review Hub-owned coordination material in place. For a
   repository-owned target, resolve every owner. Sol may inspect selected
   project evidence read-only while preparing the review Plan; Terra dispatches
   approved review units and returns the receipt without monitoring. If route
   planning is unavailable, use only the checker's manual exact-path handoff
   after normal verification fails.
3. In an owning repository, read applicable instructions, record branch, SHA,
   dirty state, and the exact review target, then inspect the candidate diff and
   enough surrounding code or tests to validate behavior.
4. Use the applicable specialized skill for security, charts, patching,
   compliance, artifacts, CI/CD, or platform evidence without weakening this
   review contract.

## Adapt the review

Infer review depth from change size, trust boundaries, compatibility, and
blast radius. A focused diff can stay compact. Large, cross-repository,
security-sensitive, migration, deployment, or release work requires deeper
contract and validation review. Do not ask the user to choose a review mode
unless two materially different targets remain ambiguous.

Use `references/review-method.md` for severity, evidence, readiness, and
cross-repository guidance.

## Report

Lead with findings ordered by severity. Each finding must name the impact,
evidence with a path and tight line range when available, and a concrete fix
direction. Then state open questions, skipped checks, and residual risk.

If no actionable findings remain, say so plainly and still report validation
gaps or unreviewed surfaces. Do not edit, comment on a pull request, request an
external review, approve, merge, deploy, or claim readiness without the
required evidence and authorization.

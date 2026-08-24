# Change review

Start with `/kepler review`, then identify the target in natural language.
Kepler infers the required depth from trust boundaries, compatibility risk,
and blast radius.

## Ownership and target

Review code, configuration, manifests, artifacts, and repository evidence in
the owning project. Review Hub-owned coordination plans or workflows in place.
Sol may inspect repository-owned evidence read-only while preparing the review
Plan. The same Sol control task dispatches any approved Terra review worker
directly into its owning project and returns the receipt without monitoring.

When the current control task is already verified as Sol with high reasoning,
create and persist the review Plan there. Do not create another control task
solely because review requires a new Plan or revision.

Record the exact pull request, base and candidate SHA, branch comparison,
working tree, plan, or architecture under review. Do not silently substitute a
different target.

## Findings-first result

Lead with actionable findings ordered by severity. Each finding names:

- the impact and triggering condition;
- the evidence, including a path and tight line range when available;
- a focused fix direction.

Then state open questions, checks run, checks skipped, and residual risk. If
there are no actionable findings, say so plainly without treating unrun checks
or unreviewed surfaces as proof of readiness.

Review is read-only by default. Fixes, pull-request comments, external review
requests, approval, merge, publication, deployment, and closure are separate
actions with their own authorization and evidence gates.

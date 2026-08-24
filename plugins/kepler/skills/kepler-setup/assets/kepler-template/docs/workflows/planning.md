# Planning work

Start with `/kepler plan`, then describe the objective in natural language.
Kepler chooses the least detail that still makes the work executable.

## Planning-only boundary

A planning-only request is read-only with respect to selected projects and
worker dispatch. Sol may inspect relevant selected-project evidence read-only,
then persist Plan and ContextPack artifacts in the Kepler control project. Sol
does not edit selected projects, create or resume workers, or implement.

Use the confirmed ArchitectureMap, live project identity, relevant repository
instructions, and scoped memory. Mark unavailable evidence explicitly; do not
invent it or dispatch merely to avoid read-only inspection.

## Right-sized output

- Small work: outcome, short ordered plan, and validation.
- Normal work: add non-goals, owner, dependencies, risk, and approvals.
- Cross-repository or high-risk work: add contract order, migration or rollout,
  rollback, and unresolved decisions.

Do not invent files, commands, owners, branches, or external facts. Mark
unknowns and identify the evidence needed to resolve them. Planning never
authorizes commit, publication, deployment, shared-environment mutation,
external communication, compliance submission, risk acceptance, or closure.

---
name: kepler-repo-bridge
description: Inspect, change, migrate, or repair optional repository instruction bridges and exact-path saved-project identities for an existing Kepler control project. Use for reference, materialized, or repo-native mode changes, bridge drift, unsafe overrides, or advanced bulk bridge work. Initial project-first setup belongs to kepler-setup.
---

# Kepler Repo Bridge

Read the owning repository's applicable `AGENTS.md` files before bridge work.
Repo rules own layout, commands, and tests; the stricter rule wins for security
and authorization.

For advanced bulk bridge configuration on an existing Kepler, read
`references/configure-bridge-repos.md` completely and follow it end to end.
That runbook is mandatory.

Before invoking Hub-local bridge or repository commands, run the installed
setup skill's `scripts/hub_compatibility.py` for the exact required
capabilities: `kepler.command.repo-plan.v1`,
`kepler.command.repo-onboard.v1`, `kepler.command.bridge-plan.v1`,
`kepler.command.bridge-install.v1`, and
`kepler.command.doctor.v1` as applicable. Do not invoke a missing
capability; return its fallback and plan-and-diff migration guidance.

Use:

- `reference`: machine-local `AGENTS.override.md` points to Hub docs.
- `materialized`: a versioned local bridge pack copies selected Hub policy.
- `repo-native`: reviewed policy is incorporated into tracked repo instructions.

Run `bin/kepler bridge plan` first. For all declarations, use `bridge plan
--all`, then the explicit `bridge install --all` apply. `bridge install` is
state-changing, returns a no-op for a valid bridge, and refuses drift or
unmanaged targets. The CLI has no in-place update mode; replace or migrate only
through a separately authorized, reviewed change. Record bridge mode, profile,
version, content digests, and per-repository receipts in ignored Hub state.

For a reference override, add only `/AGENTS.override.md` to the repository's
Git-local `info/exclude`; never modify the repo-wide ignore file for this
machine-local concern.

Read `references/bridge-contract.md`. Run Doctor after installation and verify
instruction presence, ignore protection, recorded digest, referenced Hub docs,
and unsafe override conditions.

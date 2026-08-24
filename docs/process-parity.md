# Strict process parity and exclusions

Kepler preserves the reusable operating process of the reference Hub while
excluding its private operational state. This document is the human-readable
audit. The machine-enforced mapping is
[`plugins/kepler/process-parity.json`](../plugins/kepler/process-parity.json),
and the deterministic validator is
[`process_inventory.py`](../plugins/kepler/skills/kepler-setup/scripts/process_inventory.py).

## Inventory boundary

The source reference currently has no committed index. Its root ignore policy
is therefore the authoritative allowlist. The validator runs the equivalent of:

```text
git -C <source-root> ls-files -co --exclude-standard
```

The selected baseline inventory is captured dynamically rather than asserted
as a hand-maintained count. Every selected reusable source path requires a
mapped, generalized, or explicitly justified clean-break classification. Any newly selected source path,
unclassified generated-control-project path, unclassified plugin-distribution path,
ambiguous mapping, missing candidate, invalid status, duplicate capability ID,
or count drift fails the strict inventory.

Exact source paths, absolute roots, and source-specific comparison reports are
written only under ignored `.kepler-local/`. The tracked manifest uses
neutral capability IDs and generalized selectors so distributable content does
not reveal source identities.

Source-specific vocabulary follows the same boundary. The comparator and
de-branding scanner accept an ignored external JSON map with this synthetic
shape:

```json
{
  "schema_version": "kepler.private-neutralization/v1",
  "source_control_token": "legacy-fixture-hub",
  "replacements": {
    "private-fixture-product": "product"
  },
  "deny_tokens": [
    "private-fixture-owner"
  ]
}
```

Replacement sources, the source control token, and explicit deny tokens are all
treated as prohibited distributable vocabulary. Validation checks plaintext,
hex, base64, and simple reconstructed forms. The map must remain Git-ignored
and outside plugin, template, and generated-control-project content.

## Reusable capability mapping

| Capability | Kepler counterpart |
|---|---|
| Distribution boundary | Generated control-project ignore policy plus de-branding and strict inventory |
| Coordination entrypoints | Control-project `AGENTS.md`, README, Makefile, registry, and CLI |
| Runtime and regression suite | `lib/kepler/`, `bin/kepler`, and generated Ruby tests |
| Removed workload topology | Explicit intentional exclusions; reusable domain method remains in focused plugin skills and ArchitectureMap domains |
| Architecture and workflow method | Generated `docs/` hierarchy, including the guide index and Codex UI workflow |
| Design history | Neutral coordination-layer and compliance workbench plans/specifications under `docs/superpowers/` |
| Legacy task and workflow contracts | Explicit clean-break migration evidence; Kepler v1 uses Plan, ContextPack, DispatchReceipt, and WorkerResult contracts instead |
| Project onboarding | Selection from the live saved-project catalog by opaque runtime ID and exact normalized path; no repository scan or selected-project mutation |
| Project identity and dispatch | Exact normalized path verification, separate logical/runtime IDs, search/resume-before-create, optional same-task Herdr attachment, receipt, and no monitoring |
| Worker cleanup | Exact receipt ownership, idle-state verification, task archival, branch preservation, and clean already-merged Worktree removal |
| Repository bridges | Optional advanced reference, materialized, and repo-native modes; absent by default; configured drift fails closed |
| Doctor and coordination | Stable finding codes, no-fetch repository state, ArchitectureMap/Plan contract checks, bridge integrity, sidecar checks, and disabled automation policy |
| Automation patterns | Disabled YAML specifications plus a separate approval-gated real-schedule method |
| Development and charts | Owner dispatch, secure design/review gates, manifest rendering, and rollback evidence |
| Patching | Ownership, compatibility contracts, scans, rebuild evidence, immutable digests, SBOMs, and downstream validation |
| Research | Source ledger, freshness, fact/inference separation, contradictions, gaps, and decision briefs |
| Artifact workflows | Routing to installed Word, PDF, and spreadsheet capabilities with render/inspect/iterate gates |
| Compliance and POA&M | Isolated program workspaces, evidence classification, workbook preservation, supported weakness candidates, sidecars, and human review |
| STIG | Adaptive read-only evaluation, evidence provenance, applicability and inherited-control checks, draft/export readiness, remediation routing, summaries, and deterministic CKL round trips |
| Setup | Project-first live selection, exact identity verification, explicit ArchitectureMap confirmation, idempotent apply, and no repository mutation |
| Plugin lifecycle | Exact installed/target version planning, deterministic release notes, supported same-plugin reinstall, preservation checks, and explicit separation from control-project migration |

Semantic parity remains a second gate. The strict distribution inventory proves
that every shipped candidate and plugin surface is classified and present;
`compare_hubs.py` separately probes the new coordination contracts, CLI,
Doctor, bridges, planning, artifacts, STIG, documentation, de-branding, and
local acceptance behavior while retaining historical migration evidence for
the removed lifecycle.

## Required exclusions

The source allowlist deliberately omits the following data classes. They are
not functional parity gaps:

- independent owning repositories and their Git histories;
- organization, product, program, customer, person, and machine identities;
- credentials, provider secrets, authenticated URLs, and local connection
  configuration;
- real program evidence, workbooks, controlled documents, and generated
  compliance artifacts;
- live task, report, run, cache, bridge, project, finding, and automation
  execution history;
- vulnerability scan outputs and generated handoff packets;
- VM, cluster, image, deployment, and other live runtime state;
- ignored local tools or caches that have not been deliberately generalized;
- risk acceptance, authorization decisions, submission receipts, and closure
  claims.

Kepler includes the reusable process for handling these classes, not the
private instances.

## Installed-runtime boundary

Local validation can prove generation, schemas, CLI behavior, bridge
idempotence, Plan revision/readiness gates, no-fetch Doctor behavior, de-branding, artifact
gates, deterministic CKL tools, release-ledger integrity, and read-only upgrade
planning. It cannot prove live Codex project registration, real task
creation/resume behavior, or an installed plugin update.

Installed runtime evidence remains unresolved unless a fresh task records the
exact plugin version, current candidate root, a preserved synthetic control
project, at least two exact-path project matches, distinct logical and opaque
runtime IDs, requested/effective Sol control-task and Terra worker models,
no intermediary dispatcher, stable owning-project association, optional-bridge behavior,
task create/resume identity, WorkerResult ingestion, and receipt-stop without
monitoring. Stale or cross-plugin evidence must fail.
Installed upgrade acceptance separately requires explicit authorization,
before/after exact versions, structured command results, preserved synthetic
Hub and repository state, and a fresh task that loads the target build.

## Audit command

Write all path-bearing evidence to ignored local state:

```text
python3 plugins/kepler/skills/kepler-setup/scripts/process_inventory.py \
  --source <read-only-source-root> \
  --candidate plugins/kepler/skills/kepler-setup/assets/kepler-template \
  --plugin plugins/kepler \
  --json .kepler-local/parity/process-inventory.json
```

The report includes source, generated candidate, and plugin file counts,
classification totals, unresolved items, and deterministic path-list digests.

# Memory

Scopes are `SYSTEM`, `WORKSPACE`, `DOMAIN`, and short-lived `WORK`. Types are `FACT`, `DECISION`, `CONSTRAINT`, `ATTEMPT`, `RELATIONSHIP`, `ARTIFACT`, and `SUMMARY`.

`WORKSPACE` items require a workspace. `DOMAIN` and `WORK` items require both
workspace and domain identifiers, so a partially scoped record cannot be
retrieved as global context.

Every item is sourced, scoped, timestamped, confidence-bearing, and invalidatable. Deterministic retrieval ranks scope/domain match, objective/lexical match, recency, importance, confidence, and applicable failed attempts under a fixed result and token budget. Exact duplicates are reused. Conflicting updates require explicit supersession, which invalidates the prior item without deleting it. Expired and invalidated items are excluded.

Query telemetry records candidates, selected items, estimated tokens, the hard token budget, and rejection counts for invalidation, expiry, scope, and budget. ContextPacks carry this telemetry plus their final estimate; these are deterministic estimates, not claims about provider-side token accounting. Raw chat is not durable memory.

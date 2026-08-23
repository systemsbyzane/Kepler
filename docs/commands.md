# Commands

- `/kepler setup`: propose, confirm, and persist project/domain topology; writes only approved control-project state.
- `/kepler plan`: create or revise a Plan; may read evidence but cannot dispatch or edit connected repositories.
- `/kepler dispatch`: dispatch ready units from one identified Plan revision; stale revisions and unresolved targets fail closed.
- `/kepler status`: show revision, dependencies, receipts, results, blockers, validation, and ready units.
- `/kepler review`: create a findings-first review Plan without implementation.
- `/kepler doctor`: run read-only integrity, identity, path, schema, and dispatch-capability checks.

The generated control project exposes deterministic helpers through `bin/kepler`: `architecture`, `plan`, `dispatch`, `result`, and `memory`. Run `bin/kepler help` for exact syntax.

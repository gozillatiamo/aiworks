# Ground truth first

Before you author a scenario or seed a row, establish **ground truth** — what the real system *is* and *does* — from two sources: the live **schema** (a DB MCP where one exists — e.g. `postgres_*` `list_objects` / `get_object_details`; otherwise the migration files) and the domain **docs/ADRs** (`CONTEXT*.md`, `docs/adr/`). Never assume an entity's shape or a flow's legality.

Two ground-truth checks:

1. **Seed fidelity — a seeded entity mirrors a real one.** Create every row a genuine entity has (all its auth / info / wallet / link rows), not a minimal stub. A stub that omits a row the app's own queries require (e.g. an `INNER JOIN`ed table) is invisible to that query, and the test fails for a reason that is **not** the feature — the classic false "app bug".
2. **Reachable transitions — a scenario only traverses states the app permits.** Map each step to a transition the real state machine allows; never author a journey the app forbids (e.g. chaining an action off a state a prior step just left).

**Before calling an app bug:** confirm ground truth held — the seed was a faithful entity and every step was reachable. Only then, if the app *still* contradicts the expected behaviour, **confirm with the developer** (the developer agent under the dev-cycle; otherwise flag the developer) before logging it as a defect.

**Done when:** every seeded entity's row-set is justified against the schema, and every scenario step against a reachable transition — established *before* the suite runs.

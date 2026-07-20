# ADR 0003: Use an append-oriented durable task ledger with transactional projections

- **Status:** Proposed
- **Date:** 2026-07-20
- **Issue:** [#2 — M2: Define the durable task domain model](https://github.com/kool1160/sxf-core/issues/2)

## Decision

SXF will represent task lifecycle facts in an append-oriented `task_transition_events` ledger and
maintain `tasks` as the current projection. Ecto writes the event and projection in one transaction.
Phase 1 stores the records in SQLite WAL, as selected by ADR 0002, while UUID identities and domain
rules remain independent of the database, tracker, and agent backend.

The lifecycle and preconditions in [`docs/TASK_DOMAIN.md`](../TASK_DOMAIN.md) are normative.
`BLOCKED` is nonterminal. `FAILED` and `CANCELLED` are reopenable terminal states requiring an
explicit human decision and available budget. `DEPLOYED` is permanently terminal. Unknown outcomes,
expired leases, worker loss, and budget/runtime exhaustion block rather than imply success.

## Context

Symphony keeps claims, blocked entries, retry counters, timers, usage totals, and active work in a
GenServer state struct. Its restart recovery rediscovers tracker issues and workspaces but loses that
operational history. SXF requires durable attempts, budgets, leases, evidence associations, retries,
decisions, and attributable state changes before Symphony can become the execution scheduler.

The existing architecture listed states but did not define all edges, terminal semantics,
cancellation, repair entry, or recovery behavior. Encoding provider state directly would also make
GitHub's open/closed model or a backend conversation an accidental workflow authority.

## Consequences

Positive consequences:

- a process restart cannot erase authoritative task state or retry deadlines;
- a duplicate command returns the original event or an explicit conflict;
- current-state queries remain cheap while history stays inspectable;
- provider and agent adapters can be replaced without migrating primary identities; and
- deterministic tests can supply observation times and avoid sleeps.

Costs and risks:

- the projection and event rules must remain transactional during Symphony integration;
- SQLite permits one effective writer and is not the multi-node solution;
- enum membership is enforced at the Ecto command boundary because portable SQLite `ALTER TABLE`
  check constraints are unavailable through the adapter;
- append-only protection currently depends on the domain boundary rather than database triggers;
- the local evidence byte store, inbox processor, and outbox dispatcher are still unimplemented;
  and
- future state/edge changes require explicit migration and compatibility review.

## Alternatives considered

**Mutable task rows only** were rejected because they cannot explain or replay prior decisions.

**Pure event sourcing with no projection** was rejected for Phase 1 because rebuilding every task on
each scheduler query adds complexity without improving the single-node reliability target.

**Tracker or agent-session state as authority** was rejected because those systems cannot represent
SXF's lifecycle, budgets, evidence, leases, or atomic external-action intent.

## Deferred work

- Symphony scheduler integration and durable claim acquisition.
- Content-addressed evidence-byte storage and retention.
- GitHub webhook inbox processing and external-action outbox delivery.
- Crash-injection at every future external-side-effect boundary.
- PostgreSQL migration and distributed lease semantics.
- Independent verification execution in Phase 2.

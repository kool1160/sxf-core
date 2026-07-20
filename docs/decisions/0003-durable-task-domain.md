# ADR 0003: Use an append-oriented durable task ledger with transactional projections

- **Status:** Proposed
- **Date:** 2026-07-20
- **Issue:** [#2 — M2: Define the durable task domain model](https://github.com/kool1160/sxf-core/issues/2)

## Decision

SXF will represent task lifecycle facts in an append-oriented `task_transition_events` ledger and
maintain `tasks` as the current projection. Each event has a gap-free, monotonic sequence within its
task, and the task stores the matching projection version. Ecto writes the event and projection in
one transaction.
Phase 1 stores the records in SQLite WAL, as selected by ADR 0002, while UUID identities and domain
rules remain independent of the database, tracker, and agent backend.

The lifecycle and preconditions in [`docs/TASK_DOMAIN.md`](../TASK_DOMAIN.md) are normative.
`BLOCKED` is nonterminal. `FAILED` and `CANCELLED` are reopenable terminal states requiring an
explicit human decision and available budget. `DEPLOYED` is permanently terminal. Unknown outcomes,
expired leases, worker loss, and budget/runtime exhaustion block rather than imply success.

Database constraints enforce aggregate ownership: repository registrations must belong to the
task's project, and every task/attempt pair must reference one attempt owned by that task. Human
decisions are capabilities for one exact action, represented by target type, target UUID, and target
action; the consuming transition or blocker resolution stores the decision ID and may consume it
only once. Every implemented idempotent command persists a deterministic fingerprint covering all
accepted semantic inputs and conflicts on any changed input.

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
- equal timestamps still produce one deterministic history order and projection version;
- cross-project repository and cross-task attempt associations fail at the database boundary;
- an approval cannot be replayed for a different transition or blocker action;
- current-state queries remain cheap while history stays inspectable;
- provider and agent adapters can be replaced without migrating primary identities; and
- deterministic tests can supply observation times and avoid sleeps.

Costs and risks:

- the projection and event rules must remain transactional during Symphony integration;
- SQLite permits one effective writer and is not the multi-node solution;
- enum membership is enforced at the Ecto command boundary because portable SQLite `ALTER TABLE`
  check constraints are unavailable through the adapter;
- append-only protection currently depends on the domain boundary rather than database triggers;
- callers that use a human decision must allocate the target transition UUID before recording the
  decision, adding a small amount of command-protocol ceremony;
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

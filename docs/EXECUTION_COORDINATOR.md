# Durable execution coordinator

The M3 execution coordinator connects SXF's SQLite task ledger to replaceable execution boundaries
without starting the imported Symphony application or performing live repository, container,
GitHub, or Codex operations. The ledger remains the sole workflow authority.

## Authority and dispatch

`Sxf.Execution.Coordinator` is the single dispatch service. A tick asks `TaskStore` for at most one
claim and never treats its GenServer state as task truth. `Sxf.Execution.TaskStore.Ecto` performs
the following in one immediate SQLite transaction:

1. choose a due durable retry by `(due_at, sequence, id)`, or a `READY` task by
   `(last_transition_at, id)`;
2. verify that execution budget remains and no active attempt or lease exists;
3. create the next running attempt;
4. acquire a lease with the next monotonically increasing fencing token; and
5. append the transition event and project the task to `IMPLEMENTING`.

Concurrent ticks are serialized by SQLite and the lifecycle transition. Replaying the same claim
key returns the original claim only when every accepted input has the same request fingerprint.
Terminal tasks and tasks outside the eligible states are never selected.

## Backend seams

The coordinator depends only on these provider-neutral behaviours:

- `TaskStore` owns claims, leases, events, usage, retries, blockers, reconciliation, and outcomes.
- `AgentBackend` exposes capabilities plus start, resume, inspect, and cancel operations. A start or
  resume call emits sequenced events and returns one explicit outcome.
- `WorkspaceBackend` prepares, inspects, and releases an opaque workspace reference.
- `SandboxBackend` prepares, inspects, and releases an opaque sandbox reference.

Backend inputs contain SXF task, attempt, lease, actor, and correlation identities. They do not
contain mutation functions for budgets or lifecycle state. The deterministic test implementations
are the only active backends in this change; live Codex, host command, repository, and container
effects remain out of scope.

## Events, usage, and fencing

`execution_events` is an append-only stream scoped to one task, attempt, and lease. Each event has:

- a strictly monotonic per-attempt sequence;
- the lease fencing token;
- actor, timestamp, and correlation identity;
- a stable idempotency key and full request fingerprint; and
- a structured payload.

The store accepts an exact replay but rejects a changed replay, a gap or duplicate sequence, an
expired/released lease, a non-running attempt, or any event from an older fencing token. Usage maps
contain non-negative integer deltas only. The store writes each delta through the existing durable
budget and usage commands; workers cannot replace or increase a limit. Reaching the runtime, turn,
cost, repair-cycle, or provider-retry limit creates the existing durable blocker and `BLOCKED`
transition atomically.

Lease extensions create append-only `lease_renewals` records before updating heartbeat and expiry.
An extension must occur before expiry and move expiry forward. Exact renewal replay is idempotent;
changed input conflicts.

## Outcomes, retries, and restart recovery

A successful fake execution marks the attempt succeeded, releases its lease, records a completion
event, and advances `IMPLEMENTING -> CI_RUNNING`. Deterministic failure and timeout become explicit
terminal `FAILED` outcomes; cancellation becomes `CANCELLED`. Backend unavailability consumes one
provider-retry unit, blocks the task, and records a wall-clock retry. A retry at its durable due
time resolves only system-resolvable infrastructure blockers and atomically creates the next
attempt and lease. Exhausted retry capacity retains an `exhausted` retry row and never loops.

On restart, the coordinator first reconciles expired leases from SQLite. An expired lease becomes
expired, its attempt becomes lost, and the task is blocked with a bounded recovery retry. It then
inspects still-active claims owned by its worker identity through `AgentBackend`. A missing or
unavailable session is durably completed as interrupted/backend-unavailable; a reported running
session remains owned by its existing lease. Interrupted attempts and leases are marked `lost`,
then blocked and scheduled within the provider-retry ceiling. This inspection result is evidence,
not workflow state.

The imported `SymphonyElixir.Orchestrator` remains outside `Sxf.Application`. Symphony's dispatch
ordering, exponential retry bounds, continuation, event, usage, and reconciliation behavior are
reference semantics only; its in-memory maps, timers, claims, and token totals are never consulted
as authority.

## Deliberate exclusions

This coordinator does not authenticate a GitHub App, poll or receive webhooks, clone a repository,
create branches or pull requests, run repository commands, start Docker or native Windows workers,
start Codex, store evidence bytes, verify work independently, perform repair loops, merge changes,
or start a dashboard. Those boundaries require later M3 issues and must reuse these durable claims
and backend contracts rather than introducing another state machine.

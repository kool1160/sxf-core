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

Concurrent ticks are serialized by SQLite and the lifecycle transition. A dispatch fingerprint
covers caller-accepted semantic input, including the worker, backend, actor, and explicit dispatch
contract. Control-plane-generated observation times, expiries, and correlation IDs do not make an
otherwise identical replay conflict. An exact replay reconstructs the original durable claim and
does not invoke workspace, sandbox, or agent boundaries again, whether the original execution is
active or complete. Changed semantic input conflicts. Terminal tasks and tasks outside the eligible
states are never selected.

## Supervision and control ticks

Backend execution runs in a monitored child of `Task.Supervisor`; `AgentBackend.start/2` never runs
inside the coordinator GenServer. The coordinator therefore remains responsive to lease renewal,
deadline enforcement, event persistence, cancellation, reconciliation, completion, and child
exits. The execution supervisor uses `:one_for_all` so a coordinator restart also terminates its
execution children before durable reconciliation.

The active-process map, monitors, and BEAM timer references are liveness aids only. They are not
workflow state. The coordinator owns exactly one token-fenced control timer. Its deadline is the
earliest active lease-renewal, runtime, lease-expiry, or bounded reconciliation deadline. Moving
that deadline cancels the prior timer; a stale cancelled message is ignored and cannot start
another timer chain. `control_tick_ms` is the maximum interval before durable orphan
reconciliation, not a second polling authority. A production control tick reads a trusted clock
and test code can pass an explicit observation time to the same control path. Restart recovery
reconstructs claims, renewal sequence, and absolute runtime deadlines from SQLite; timer state is
discardable.

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

Each event retains the backend's claimed `occurred_at`, but lease currency and expiry are checked
against the control plane's separately supplied, trusted `observed_at`. A backdated event observed
after expiry is stale. The store accepts an exact replay but rejects a changed replay, a gap or
duplicate sequence, an expired/released lease, a non-running attempt, or any event from an older
fencing token. Usage maps
contain non-negative integer deltas only. The store writes each delta through the existing durable
budget and usage commands; workers cannot replace or increase a limit. Reaching the runtime, turn,
cost, repair-cycle, or provider-retry limit creates the existing durable blocker and `BLOCKED`
transition atomically. After an accepted positive runtime delta, the same transaction calculates
the tightest durable remaining runtime and moves the attempt's persisted absolute deadline to the
earlier of its current value and `trusted observed_at + remaining runtime`. Exact event replay does
not move the deadline or record usage twice. The coordinator reloads that field into the active
entry and reschedules its one control timer when the deadline becomes earlier.

While an execution child remains active, the coordinator renews before expiry without requiring a
backend heartbeat. Lease extensions create append-only `lease_renewals` rows with a monotonic
per-lease sequence and a deterministic key derived from the lease and sequence before updating the
heartbeat and expiry. The expiry formula is exactly `trusted renewed_at + lease_ttl_ms`; it never
adds a TTL to the prior expiry. Configuration validation requires
`0 < lease_renewal_interval_ms < lease_ttl_ms` and `control_tick_ms > 0`, so an on-time renewal
strictly advances expiry while remaining bounded to one TTL after the latest heartbeat. An
extension must occur before expiry and move expiry forward. Exact renewal replay is idempotent;
changed input conflicts. Stale or failed renewal terminates the execution child, invokes
cancellation, releases only resources scoped to that fenced context, and prevents later events
from being authoritative.

## Outcomes, retries, and restart recovery

A successful fake execution marks the attempt succeeded, releases its lease, records a completion
event, and advances `IMPLEMENTING -> CI_RUNNING`. Deterministic failure and a backend-declared
timeout become explicit `FAILED` outcomes; cancellation becomes `CANCELLED`. A backend declaration
is distinct from control-plane runtime enforcement.

The initial effective runtime deadline is derived from the attempt start and the tightest
applicable durable runtime budget and is persisted on the attempt. Positive usage can only move it
earlier as described above. When a hanging backend reaches it, the coordinator terminates the
execution child, calls `AgentBackend.cancel/1` exactly once for that controlled stop, releases
prepared resources, records the remaining runtime usage exactly once, exhausts the budget, creates
the runtime blocker, finalizes the attempt and lease, and leaves the task `BLOCKED`. Cancellation
and cleanup failures remain structured completion metadata; neither can turn the primary outcome
into success. An event first observed at or after the deadline is rejected. Later events are stale.

The initial execution attempt consumes no provider retry. Backend unavailability, an interrupted
session, and an expired lease all call one durable provider-retry command. In the same transaction,
that command either reserves one unit and creates a scheduled retry or creates an explicit
`exhausted` retry. `max_provider_retries = N` therefore permits exactly N retry attempts after the
initial attempt. The Nth reservation may fire; its budget becomes exhausted when that retry is
claimed, preventing an N+1 reservation without preventing the already-authorized attempt. Exact
recovery replay consumes nothing twice. Retry ordering remains `(due_at, sequence, id)` with capped
exponential backoff and deterministic task-derived jitter.

A retry at its durable due time resolves only system-resolvable infrastructure blockers and
atomically creates the next attempt and lease. Exhausted retry capacity never loops or becomes
success.

On restart, the coordinator first reconciles expired leases from SQLite. An expired lease becomes
expired, its attempt becomes lost, and the task is blocked with a bounded recovery retry. It then
inspects still-active claims owned by its worker identity through `AgentBackend` and revalidates the
lease, fencing token, running attempt, and persisted runtime deadline after inspection. A session
reported as running is resumed exactly once through a monitored `AgentBackend.resume/2` child only
when the backend declares continuation support and the attempt has a durable session ID. Resume
preserves the attempt, lease, fencing token, session, event sequence, renewal schedule, and runtime
deadline; it does not prepare a new workspace or sandbox. If continuation is unsupported, the
session identity is absent, inspection is missing/finished/unknown, supervised resume startup
fails, or the resume call becomes unavailable, the coordinator cancels when supported and durably
marks the attempt and lease lost through the existing interrupted/retry command. A finished
inspection is never inferred to be success without a durable accepted completion event.

Every active durable claim therefore becomes locally supervised, explicitly interrupted, expired,
or timed out; none remains active but unowned. Repeated reconciliation skips locally owned entries,
so it cannot launch a duplicate resume. The single production control timer also performs bounded
periodic reconciliation of durable claims not present in the local map, allowing a still-running
coordinator to detect orphaned or expired leases instead of relying only on startup recovery.

The imported `SymphonyElixir.Orchestrator` remains outside `Sxf.Application`. Symphony's dispatch
ordering, exponential retry bounds, continuation, event, usage, and reconciliation behavior are
reference semantics only; its in-memory maps, timers, claims, and token totals are never consulted
as authority.

Workspace and sandbox preparation and release are fenced by the claim context. If sandbox
preparation fails after workspace preparation, the workspace is released. After agent startup,
both prepared resources are released on every reported outcome. Cleanup failures are preserved in
the completion event and returned coordinator result without replacing the primary outcome.

## Deliberate exclusions

This coordinator does not authenticate a GitHub App, poll or receive webhooks, clone a repository,
create branches or pull requests, run repository commands, start Docker or native Windows workers,
start Codex, store evidence bytes, verify work independently, perform repair loops, merge changes,
or start a dashboard. Those boundaries require later M3 issues and must reuse these durable claims
and backend contracts rather than introducing another state machine.

# Durable task domain

This document is the normative Phase 1 contract for SXF task identity, persistence, lifecycle, and
recovery. It implements [ADR 0002](decisions/0002-symphony-phase-1-foundation.md) and the decision in
[ADR 0003](decisions/0003-durable-task-domain.md). Provider trackers, agent backends, dashboards,
and worker processes are projections or clients of this model; none is a workflow authority.

## Scope

The current SXF-owned code provides the durable layer and M3 coordinator needed to adapt accepted
Symphony execution semantics without starting its orchestrator:

- Ecto schemas and a versioned migration;
- SQLite configured for WAL mode, foreign keys, immediate write transactions, and a busy timeout;
- UUID identities for durable records and correlations;
- a pure lifecycle state machine;
- transactional task creation and transitions;
- idempotent attempt, retry, usage, blocker-resolution, and human-decision commands;
- durable retry deadlines, budgets, usage, leases, fenced execution events, lease renewals,
  blockers, and restart queries;
- atomic eligible-task and due-retry claims through provider-neutral execution contracts; and
- inbox/outbox reference records that reserve integration boundaries without implementing them.

It deliberately activates no live tracker, agent runtime, repository workspace, sandbox, evidence
byte store, webhook processor, external-action dispatcher, or user interface. The coordinator is
tested only with deterministic boundary fakes. The quarantined upstream application is compiled
for conformance only and is not a second workflow authority.

## Durable records and identity

All primary keys and correlation IDs are canonical UUID strings. A caller may allocate a UUID
before submitting a create command so a retry can address the same record. Provider IDs and backend
session IDs are opaque strings attached to stable SXF IDs; they never become primary keys.

| Record | Purpose and durable identity |
| --- | --- |
| `projects` | Stable project ID and lifecycle metadata. |
| `repository_registrations` | Stable repository ID plus opaque provider/external identity. Unique by `(provider, external_id)`. |
| `actors` | Stable identity for a human, system, worker, agent backend, or external system. |
| `tasks` | Current task projection, saved resume state, terminal timestamp, monotonic transition sequence, and optimistic lock version. |
| `task_attempts` | Ordered, bounded execution/repair attempt with opaque backend and session references. |
| `task_transition_events` | Append-oriented prior/result state fact with a task-local sequence, actor, reason, time, correlation, idempotency key, request fingerprint, and any authorizing human-decision reference. |
| `evidence_references` | Immutable evidence metadata: kind, content hash, storage URI, producer, task/attempt, size, and finalization time. |
| `event_evidence_references` | Many-to-many attachment of finalized evidence to a transition. |
| `budgets` | Exact integer task/attempt limits for cost, runtime, turns, repairs, and provider retries. |
| `usage_entries` | Append-oriented, idempotent increments against one budget. |
| `retry_schedules` | Wall-clock `due_at`, sequence, reason, resume state, and durable status. |
| `worker_leases` | Worker claim, expiry/heartbeat, and monotonically increasing fencing token. |
| `lease_renewals` | Append-only fingerprinted lease extensions; each extension must move expiry forward. |
| `execution_events` | Append-only structured backend facts with attempt-local sequence, lease fencing token, actor, correlation, idempotency fingerprint, and payload. |
| `blockers` | Active/resolved stop reason and the state to resume after resolution. |
| `human_decisions` | Explicit approval, rejection, unblock, cancellation, reopen, deploy, or budget-override decision scoped to one identified transition or blocker-resolution action. |
| `external_event_inbox_references` | Unique external delivery reference and payload hash for future idempotent intake. |
| `external_action_outbox_references` | Unique external action intent, payload hash, due time, and observable outcome status. |

No field is named for GitHub, Linear, Codex, or another concrete provider. Provider-specific values
belong in adapter-owned metadata or opaque reference fields.

Attempt creation is legal only while a task is `READY`, `CHANGES_REQUESTED`, or `BLOCKED`, and its
sequence must be exactly one greater than the last durable attempt. This prevents duplicate or
skipped attempt identities after restart.

Ownership is structural, not a caller convention. A task's repository registration must belong to
the task's project. Every record that carries both `task_id` and `attempt_id` has a composite foreign
key to the attempt's `(id, task_id)`, and transition/evidence attachments carry and constrain their
common task ID. Commands also reject mismatches before attempting a write. Adapter bugs or direct
database writes therefore cannot associate an attempt, evidence reference, budget, lease, blocker,
retry, usage entry, execution event, lease renewal, transition, or outbox action with a different
task.

`task_attempts.execution_event_sequence` is the durable projection version for backend events.
Accepting an event and incrementing that projection happen in one transaction. The next event must
be exactly one greater. Its lease must be active and unexpired, its fencing token must be the newest
token for the task, and its attempt must still be running. Exact replay returns the original row;
reuse with any different accepted input conflicts. See
[`EXECUTION_COORDINATOR.md`](EXECUTION_COORDINATOR.md).

## Authority and transaction boundary

`task_transition_events` is the append-oriented history; `tasks.state` is its current query
projection. `Sxf.Tasks` writes both in one database transaction. A successful transition therefore
cannot expose a projection without its history fact or a history fact without its projection.

Every transition command requires:

- the stable task ID;
- resulting state;
- actor ID;
- non-empty reason and optional stable reason code;
- caller-supplied UTC timestamp;
- correlation UUID;
- task-scoped idempotency key; and
- evidence reference IDs when that edge requires evidence.

The event records the prior and resulting states, actor, reason, timestamp, correlation, attempt,
request fingerprint, metadata, evidence associations, and any decision that authorized it. Creation
is sequence 1. Every later event receives `tasks.transition_sequence + 1` in the same transaction
that advances the projection, and `(task_id, sequence)` is unique. `task_history/1` orders by this
sequence, so equal timestamps remain deterministic and gaps or duplicate projection versions fail.
The optimistic lock makes conflicting writes fail rather than silently overwrite a projection.
SQLite's immediate write transaction serializes the single-node Phase 1 writer; the lock remains
useful when the store migrates. An event timestamp older than the task's last transition is rejected
as out of order; equal timestamps are allowed because sequence, not wall-clock precision, orders
facts.

An authorizing human decision names its exact `target_type`, UUID `target_id`, and `target_action`.
Transition decisions target the caller-preallocated transition-event ID and resulting state;
blocker decisions target the blocker ID and `resolve:<blocker-kind>` action. The command verifies
task ownership, human actor authority, decision kind, approval, and exact scope. The transition or
blocker-resolution row persists the decision ID, and a unique constraint prevents the same decision
from being consumed twice. A prior task-level approval cannot authorize a later or unrelated action.

The application command boundary enforces state values and preconditions. Foreign keys, unique
indexes, non-null columns, and optimistic locks provide database-level structural protection.
SQLite cannot add portable `CHECK` constraints through the chosen Ecto adapter, so enum membership
is deliberately enforced in changesets and the state machine rather than a SQLite-only trigger.

## Lifecycle

The creation edge is `nil -> DISCOVERED`. The following table is exhaustive. “Operational stop”
means `BLOCKED`, classified terminal `FAILED`, or authorized `CANCELLED` is also legal from that
nonterminal state. A `BLOCKED` task may resume only to its saved `resume_state`, even though any
nonterminal state can be the saved value.

| State | Legal incoming | Legal outgoing | Preconditions and meaning |
| --- | --- | --- | --- |
| `DISCOVERED` | creation; `BLOCKED` resume | `SPECIFIED`; operational stop | Creation is the only edge with no prior state. |
| `SPECIFIED` | `DISCOVERED`; `BLOCKED` resume | `PLANNED`; operational stop | The task contract is explicit enough to plan. |
| `PLANNED` | `SPECIFIED`; `BLOCKED` resume | `READY`; operational stop | Dependencies and execution plan are known. |
| `READY` | `PLANNED`; approved reopen from `FAILED`/`CANCELLED`; `BLOCKED` resume | `IMPLEMENTING`; operational stop | Implementation requires a running attempt, unexpired lease, and available budget. |
| `IMPLEMENTING` | `READY`; `CHANGES_REQUESTED`; `BLOCKED` resume | `CI_RUNNING`; operational stop | Repair entry additionally requires remaining repair budget. |
| `CI_RUNNING` | `IMPLEMENTING`; `BLOCKED` resume | `VERIFYING`; `CHANGES_REQUESTED`; operational stop | Either normal result requires finalized `check_result` evidence. |
| `VERIFYING` | `CI_RUNNING`; `BLOCKED` resume | `APPROVED`; `CHANGES_REQUESTED`; operational stop | Either verdict requires finalized `verification_result` evidence. Phase 2 will supply an independent verifier. |
| `CHANGES_REQUESTED` | `CI_RUNNING`; `VERIFYING`; `APPROVED`; `STAGING`; `RELEASE_READY`; `BLOCKED` resume | `IMPLEMENTING`; operational stop | A repair starts a new/running attempt with lease and remaining total and repair budget. |
| `APPROVED` | `VERIFYING`; `BLOCKED` resume | `STAGING`; `CHANGES_REQUESTED`; operational stop | Later evidence may invalidate approval and request repair. |
| `STAGING` | `APPROVED`; `BLOCKED` resume | `RELEASE_READY`; `CHANGES_REQUESTED`; operational stop | Staging failure returns to bounded repair, not blind retry. |
| `RELEASE_READY` | `STAGING`; `BLOCKED` resume | `DEPLOYED`; `CHANGES_REQUESTED`; operational stop | Deployment requires an approved human `deploy_approval` decision. |
| `BLOCKED` | every other nonterminal state | saved nonterminal resume state; classified `FAILED`; authorized `CANCELLED` | Entry requires an active blocker. Resume requires all blockers resolved and exact resume-state match. Policy, approval, operator-input, ambiguity, and exhausted-budget blockers require an approved human decision to resolve. |
| `FAILED` | every nonterminal state, including `BLOCKED` | approved reopen to `READY` | Reopenable terminal. Entry requires a system/human actor and terminal/unrecoverable classification. Reopen requires human decision and fresh available budget. |
| `CANCELLED` | every nonterminal state, including `BLOCKED` | approved reopen to `READY` | Reopenable terminal. Entry requires system/human authority or an approved cancel decision. Reopen requires human decision and fresh available budget. |
| `DEPLOYED` | `RELEASE_READY` | none | Permanently terminal. Further work is a new task, preserving deployed history. |

`BLOCKED` is nonterminal. `FAILED` and `CANCELLED` are terminal snapshots that can be reopened only
through a new auditable human decision. `DEPLOYED` cannot be reopened. Self-transitions and skipped
happy-path states are illegal.

## Failure, retry, and recovery semantics

- Transient infrastructure or provider failure creates a durable retry schedule. `due_at`, not a
  BEAM timer reference, determines eligibility. Ordering is due time, sequence, then stable ID.
- Deterministic check or verification failure uses `CHANGES_REQUESTED` with finalized evidence; it
  is not blindly retried.
- Policy, dependency, ambiguity, operator input, exhausted budget/runtime, worker loss, lease
  expiry, and indeterminate outcomes use a durable blocker and `BLOCKED` transition.
- Reaching an exact configured budget limit exhausts it. Recording the usage entry, changing the
  budget status, creating the blocker, and transitioning the task are atomic.
- Lease reconciliation takes an explicit observation time. An expired lease becomes `expired`, its
  running attempt becomes `lost`, the task becomes `BLOCKED`, and a bounded retry row is scheduled.
  Retry backoff starts at 10 seconds, doubles by sequence, applies deterministic task-derived jitter
  of up to 20 percent, and caps at 300 seconds.
- If provider-retry capacity is unavailable, the retry row is retained as `exhausted`; the system
  does not loop or convert the unknown attempt into success.
- `restart_snapshot/1` derives nonterminal tasks, due retries, stale leases, and due pending/unknown
  outbox actions from SQLite only. Scheduler memory may be discarded without losing authority.

## Idempotency

Transition keys are unique within a task. A deterministic SHA-256 fingerprint covers every accepted
input that can change command meaning, including caller IDs, metadata, evidence lists, blocker
details, optional completion fields, decision targets, and resolution details. The same key and same
request returns the original record without adding history; the same key with any semantically
different accepted input returns `:idempotency_conflict`.

Task creation, transitions/blocking, attempts, retries, usage entries, blocker resolutions, and
human decisions persist their request fingerprint beside the idempotency key. Reconciliation derives
keys and fingerprints from durable identities such as a lease ID. Budget, inbox, outbox, and lease
records reserve stable keys or natural unique scopes for their future command handlers. Unknown
outbox state remains `unknown` until observed; it is never inferred to be successful.

## Evidence rules

The schema persists content hashes and references, not artifact bytes. `check_result` evidence is
required to leave `CI_RUNNING`; `verification_result` evidence is required for a verification
verdict. Referenced evidence must exist, belong to the same task, and be finalized. Associations are
inserted in the transition transaction.

The content-addressed byte store, redaction/finalization implementation, retention, and backup are
deferred. A workspace path, model message, or unfinalized output is not evidence.

## Migration and versioning

The initial migration is additive because no previous application tables exist. Domain IDs remain
UUID strings across a future PostgreSQL migration. Provider/backend references are opaque, and the
state machine has no SQLite query semantics, so storage replacement does not rename domain IDs.

Rollback before production data exists is `mix ecto.rollback`. After task history exists, dropping
these tables is destructive and requires an export/restore plan; migrations must preserve transition
events and evidence associations. New states or edge semantics change a durable public contract and
require an ADR plus forward/backward compatibility tests.

## Verification

The deterministic suite covers every possible state pair, special preconditions, stable identity,
transition/event atomicity, ownership violations at command and database boundaries, exact decision
scope and durable consumption links, mutations of every accepted idempotent-command input,
same-timestamp transition ordering, evidence attachment, execution leases, cancellation/reopen,
blocking/unblocking, budget exhaustion, durable retry deadlines, unknown outcomes, stale-lease
restart reconciliation, inbox/outbox uniqueness, and actual SQLite WAL/foreign-key pragmas. Tests
supply fixed timestamps and inspect durable rows; no test sleeps.

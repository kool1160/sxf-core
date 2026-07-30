# Reliability Model

SXF must continue operating correctly when agents fail, tools return partial results, processes restart, webhooks are duplicated, CI is flaky, and model output is malformed.

## Reliability principles

- Persist workflow state outside model context.
- Make every consequential operation idempotent.
- Prefer deterministic validation over interpretation.
- Classify failures before retrying.
- Bound every retry, runtime, and cost loop.
- Preserve evidence from failed attempts.
- Never convert an unknown state into success.
- Escalate with a useful failure package rather than a vague error message.

## Idempotency

Webhook processing, branch creation, comments, labels, task transitions, workspace creation, and status publication must accept stable idempotency keys. Replaying an event must not duplicate work or corrupt state.

The implemented transition boundary scopes keys to a task and fingerprints the semantic request.
The external-issue intake boundary derives its observation identity from stable provider,
repository, issue, and source-version values and fingerprints every accepted semantic field. An
exact replay returns the original durable result; reusing an identity with different content is an
explicit conflict. Later source versions create new inbox facts while reconciling the same
repository-scoped task. See [`TASK_DOMAIN.md`](TASK_DOMAIN.md).

The GitHub one-shot poller orders observations by `updated_at` and a stable issue-ID tiebreaker,
then hashes a canonical semantic observation rather than raw HTTP bytes. JSON property order,
whitespace, pagination envelopes, provider request IDs, receive times, and label ordering do not
change that hash. It fetches every bounded page before normalization, so authentication,
rate-limit, malformed repository, later-page, or pagination-limit failure creates no partial task
set. Exact repeated polls replay the durable result; a later source version reuses the task; the
same version with changed canonical content remains an explicit conflict.

Connected-project registration uses `(provider, stable external repository ID)` as its natural
identity. Its semantic fingerprint includes repository metadata, registering actor, and the
normalized policy-bounded manifest, but excludes raw representation, timestamp, and correlation
envelopes. Equivalent YAML and JSON therefore replay one registration; changed normalized authority
or metadata conflicts. Project and repository rows commit together in one immediate SQLite
transaction, so validation, actor, constraint, database, and concurrent-writer failures cannot
leave an orphan project. Lookup and replay depend only on durable SQLite state after restart.

Manifest-gated preparation is naturally unique by task ID. Its fingerprint pins the accepted
registration, sole processed issue observation, system actor, ordered command plan, and effective contract while
excluding fresh timestamp, correlation, and idempotency envelopes. One immediate transaction
creates the preparation, task budget, and three lifecycle facts through `READY`. Exact replay and
independent SQLite contention return that one authority; changed source or manifest semantics
conflict. Multiple processed source versions durably block for `operator_input`; invalid manifest
authority durably blocks for `policy`; neither failure creates a preparation or budget.

Execution claims revalidate the complete preparation, its sole active task budget, the pinned
registration fingerprint, and source-version freshness. The preparation semantic fingerprint is
part of claim idempotency and the frozen contract is loaded into both claim and context. Caller
dispatch data is not accepted as authority.

## Failure classes

### Transient infrastructure failure

Examples: provider timeout, temporary network error, unavailable runner. Retry with exponential backoff and jitter.

### Deterministic task failure

Examples: test failure, type error, manifest validation error. Do not blindly retry the same action. Route to repair with the evidence.

Connected-project manifest failures include a stable code, JSON Pointer path, and actionable
message. Unsupported versions and policy-ceiling violations are rejected explicitly. YAML and JSON
decode inside time/heap boundaries and enforce nesting, node, and container limits; YAML references
are rejected before expansion. Both formats normalize to the same bounded representation, and
validation has no command-execution or repository-mutation side effects.

### Agent execution failure

Examples: malformed output, tool loop, context exhaustion, no progress. Resume when safe, otherwise start a new bounded attempt with summarized state.

### Policy failure

Examples: prohibited action, protected path, missing approval, exceeded permission. Block immediately; do not retry around policy.

### Product ambiguity

Examples: conflicting acceptance criteria or missing expected behavior. Escalate to a human decision rather than inventing requirements.

## Budgets

Every task and attempt must have explicit limits for:

- Monetary cost.
- Wall-clock runtime.
- Agent turns or tool actions.
- Repair cycles.
- Provider retries.
- Workspace resources.

Budget exhaustion transitions the task to `BLOCKED` with evidence and recommended next action.

`BLOCKED` is a durable nonterminal state with a saved resume state. Runtime exhaustion, worker/lease
loss, and indeterminate outcomes use the same rule. A task resumes only after all blockers are
resolved and any required human decision is recorded.

## Health and recovery

The control plane must reconcile desired state with observed state after restart. It should detect and recover:

- Orphaned workspaces.
- Running attempts with no heartbeat.
- Completed CI not yet consumed.
- Pull requests whose branch or status changed externally.
- Duplicate webhook deliveries.
- Rate-limit suspension and recovery.

The imported Symphony scheduler's in-memory claims, blocked entries, timers, and retry counters are
not authoritative and are not started. The SXF coordinator derives work, leases, retry deadlines,
persisted runtime deadlines, and restart actions from SQLite. Supervised execution and resume
children keep agent calls outside the coordinator mailbox. One owned control timer wakes at the
earliest active deadline or bounded durable-reconciliation interval; replacement cancels its prior
reference, and stale timer messages are harmless. Lease expiry remains bounded to one TTL after
the latest trusted heartbeat, while positive runtime usage can only move the durable deadline
earlier. On restart or periodic reconciliation, a running session is safely resumed only with
declared continuation support, a current fenced claim, an unexpired runtime deadline, and a durable
session ID. Every other observation becomes an explicit interruption, expiry, or timeout with
bounded retry; no durable active execution remains unowned and unknown state never becomes
success. Backend completion uses its trusted control-plane observation time to arbitrate against
the persisted deadline in the durable transaction; timer delivery order cannot admit an on- or
after-deadline result. Tracker, workspace, sandbox, and backend observations are reconciliation
evidence only.
See [`EXECUTION_COORDINATOR.md`](EXECUTION_COORDINATOR.md).

## Evidence requirements

A successful task should include, as applicable:

- Commit and diff identity.
- Exact commands executed.
- Exit status and relevant logs.
- Test counts and failures.
- Build artifacts or deployment identity.
- Acceptance-criterion verdicts.
- Screenshots or browser traces for user-facing behavior.
- Security and migration findings.
- Remaining known risks.

Missing required evidence means the task is not verified.

`Sxf.Evidence` makes this evidence byte-addressable rather than metadata-only. It stages bounded
bytes, derives their SHA-256 and size, publishes one non-overwriting local content address, and
persists an immutable attributed reference with semantic idempotency. Exact bytes deduplicate
physically; references retain task and attempt ownership. `get`, `verify`, `audit`, and task
transition attachment re-hash the stored regular file. Missing or corrupt bytes cannot become a
successful transition.

The filesystem and SQLite cannot commit atomically. A crash after blob publication and before
reference commit can create an inert orphan, never a trusted reference; deterministic audit reports
it. Repo restart tests prove that reference and byte verification depend only on durable state.
Retention, garbage collection, and coordinated database/evidence backup remain explicit deferred
operations rather than implicit cleanup.

## Flaky checks

A check may be retried only under a documented flake policy. Repeated success after failures must remain visible in evidence. SXF must not hide instability by rerunning until green.

## Observability

At minimum, record:

- Structured logs with project, task, attempt, and correlation IDs.
- State transitions and actor identity.
- Provider usage and cost.
- Tool calls and outcomes.
- Queue and execution latency.
- Retry and repair reasons.
- Final outcome and human intervention.

## Service objectives for the first usable release

- No task state is stored only in agent memory.
- Duplicate events do not create duplicate attempts.
- A crashed worker can be safely reconciled.
- Every accepted result has deterministic-check evidence.
- Every meaningful implementation has independent-verification evidence.
- Every blocked task explains why it stopped and what decision is required.

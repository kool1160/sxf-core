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
An exact replay returns the original event; reusing a key for different content is an explicit
conflict. See [`TASK_DOMAIN.md`](TASK_DOMAIN.md).

## Failure classes

### Transient infrastructure failure

Examples: provider timeout, temporary network error, unavailable runner. Retry with exponential backoff and jitter.

### Deterministic task failure

Examples: test failure, type error, manifest validation error. Do not blindly retry the same action. Route to repair with the evidence.

Connected-project manifest failures include a stable code, JSON Pointer path, and actionable
message. Unsupported versions are rejected explicitly. YAML and JSON normalize to the same bounded
representation, and validation has no command-execution or repository-mutation side effects.

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

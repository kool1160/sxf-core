# Manifest-gated task preparation

`Sxf.TaskPreparation.prepare/1` is the M3 boundary between untrusted issue intake and executable
durable work. It reads only SQLite records already accepted through the project registry and issue
inbox. It performs no network access, repository read or mutation, command execution, workspace
creation, sandbox creation, agent invocation, or GitHub mutation.

## Authority and identity

Preparation is naturally unique by durable task ID. The command requires a system actor, trusted
preparation timestamp, correlation ID, and idempotency key. Its semantic fingerprint covers the
task and project identities, repository registration and fingerprint, latest processed source
observation and payload hash, preparing actor, and complete effective contract. Timestamp,
correlation, and idempotency envelopes do not change otherwise identical semantics.

The task must still be `DISCOVERED`. Its project must be active, its repository registration must
belong to that project, and the registration must contain a complete accepted `0.1` normalized
manifest. Exactly one processed inbox source version must belong to the same task, provider,
stable repository ID, and stable issue ID. Multiple processed versions before preparation
atomically create an `operator_input` blocker and move `DISCOVERED -> BLOCKED`; M3 does not guess
which version to execute. A later observation after preparation revokes claim eligibility rather
than silently replacing already prepared work.

## Effective contract

The immutable preparation record pins:

- stable task, project, repository-registration, provider repository, and issue identities;
- the accepted registration fingerprint and manifest schema version;
- the exact processed inbox record, source version, and canonical payload hash;
- bounded untrusted issue title, body, and display metadata;
- repository owner/name, clone URL, and default branch;
- inert normalized commands and the ordered execution plan (`install`, optional `lint`, optional
  `typecheck`, `test`, optional `integrationTest`, optional `build`);
- effective autonomy and verification requirements;
- protected paths, prohibited actions, and allowed network domains; and
- exact durable M3 task budgets.

Issue content is request data only. It cannot replace or add commands, authorize branch or
pull-request mutation, weaken verification or restrictions, broaden network access, change
repository identity, or raise a budget.

Preparation requires the accepted manifest to authorize `createBranches` and `openPullRequests`,
explicitly deny `mergeToDefault` and `deployToProduction`, retain deterministic install and test
commands, and fit inside ADR 0004's M3 ceilings. A missing, malformed, or over-authority manifest
atomically creates a `policy` blocker and moves `DISCOVERED -> BLOCKED`; it creates no preparation
or budget. The task budget preserves the manifest's equal-or-lower cost, runtime, turn, and
zero-repair limits, converts runtime minutes to exact integer milliseconds, and applies the
approved provider-retry limit of two.

## Atomic promotion and replay

One immediate SQLite transaction creates:

1. one immutable preparation record;
2. one active task budget; and
3. the attributed, monotonic `DISCOVERED -> SPECIFIED -> PLANNED -> READY` transition sequence.

Any validation, actor, ownership, state, constraint, or database failure rolls back all three.
Exact semantic replay returns the original preparation, budget, and events. Changed actor,
registration, source observation, payload, or effective contract conflicts. Independent SQLite
connections serialize to one preparation and one budget; lookup after Repo restart depends only
on durable state.

The coordinator can claim a task only while exactly one complete preparation and its one active
task budget remain coherent, the registration fingerprint is unchanged, and no newer processed
source observation exists. The claim and provider-neutral execution context carry the immutable
preparation, contract, and semantic fingerprint. Caller `dispatch_input` is rejected and cannot
replace or supplement durable authority.

Preparation creates no attempt, lease, retry, blocker, usage, evidence, outbox action, workspace,
sandbox, branch, agent session, or external effect. `READY` only makes the task eligible for the
existing durable coordinator; it does not dispatch the task.

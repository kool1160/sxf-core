# SXF Locked Milestone Contract

## Status

This document defines the mandatory implementation sequence for SXF.

The sequence is binding on:

- Human operators
- ChatGPT project chats
- Codex and other coding agents
- Builders
- Verifiers
- Issue authors
- Pull-request reviewers

No participant may silently skip, combine, reorder, redefine, or declare completion of a milestone.

GitHub is the source of truth.

## North Star

SXF must repeatedly take a real, scoped GitHub issue and produce a tested, independently verified, maintainable pull request with durable evidence and minimal human intervention.

The required complete loop is:

```text
GitHub issue
→ durable SXF task
→ isolated workspace
→ coding-agent attempt
→ deterministic repository checks
→ independent verification
→ bounded repair when required
→ pull request with durable evidence
→ explicit accepted, blocked, or failed outcome
```

Work that does not directly enable, verify, secure, operate, or measure this loop belongs in deferred work.

## Milestone governance rules

### 1. One active milestone

Only one milestone may be considered active at a time.

Work from a later milestone must not begin before the active milestone's completion gate has been satisfied.

### 2. Completion requires merged evidence

A milestone is complete only when:

- Its required issues are merged.
- Its acceptance criteria are satisfied.
- Required deterministic checks pass.
- Independent review is complete where required.
- Known failures and limitations are recorded.
- The repository documentation reflects the implemented behavior.
- The completion evidence exists in GitHub.

A conversation, agent report, local unpushed change, passing model judgment, or demonstration alone cannot complete a milestone.

### 3. No silent scope expansion

When work reveals an additional requirement:

1. Determine whether it is necessary for the active milestone's acceptance criteria.
2. If necessary, add it explicitly to the current issue or create a blocking issue.
3. If unnecessary for the current gate, record it as deferred work.
4. Do not implement it merely because it would be convenient or impressive.

### 4. Interfaces do not authorize future implementation

A current milestone may introduce a narrow interface or durable placeholder needed to avoid coupling.

That does not authorize implementation of the future subsystem behind that interface.

Examples:

- An `AgentBackend` interface does not authorize a second backend before M5.
- Inbox and outbox records do not authorize GitHub delivery processing before M3.
- Verifier evidence fields do not authorize verifier execution before M4.
- Operator metadata does not authorize a dashboard before M6.

### 5. Milestones cannot be bypassed

Later work may not be used to compensate for an incomplete earlier milestone.

Examples:

- A dashboard cannot compensate for unreliable durable state.
- Model review cannot override failed deterministic checks.
- Multiple backends cannot compensate for an unproven single-backend loop.
- More retries cannot compensate for broken idempotency.
- Human babysitting cannot be treated as autonomous success.

### 6. Changing the sequence

The milestone order may change only when verified evidence shows that the existing sequence is invalid, unsafe, or impossible.

Changing the order requires:

- A dedicated GitHub issue
- An architecture or governance decision record
- Explicit human approval
- A merged pull request updating this document and affected roadmap material

No chat or agent may change the sequence independently.

### 7. Emergency work

A security, data-integrity, licensing, or destructive-behavior defect may interrupt the active milestone.

Emergency work must:

- Be recorded in GitHub.
- Be limited to the defect.
- Include regression evidence.
- Not be treated as advancement into a later milestone.
- Return the project to the active milestone afterward.

# M1 — Symphony Foundation

## Goal

Select the Phase 1 architectural foundation using verified evidence.

## Required outcome

- OpenAI Symphony is evaluated.
- One adoption approach is selected.
- The implementation stack is selected.
- Licensing, upgrade, security, and migration risks are documented.
- No production implementation begins before the decision is accepted.

## Completion gate

M1 is complete when ADR 0002 is accepted and merged.

## Status

**Complete.**

## Locked decision

SXF will fork and harden Symphony's Elixir/OTP reference implementation while preserving an upstream-tracking boundary.

# M2 — Durable Core

## Goal

Create the durable, provider-independent contracts required before any autonomous execution begins.

## Required work

### Issue #2 — Durable task domain

Implement and verify:

- Projects
- Repository registrations
- Tasks
- Attempts
- Transition events
- Actors
- Correlation identifiers
- Budgets and usage
- Retry schedules
- Worker leases
- Blockers
- Human decisions
- Evidence references
- Inbox and outbox references
- Legal task-state transitions
- Atomic projection and transition history
- Idempotency
- Restart reconstruction

### Issue #3 — Connected-project manifest validation

Implement and verify:

- Explicit manifest versioning
- YAML and JSON loading
- Schema validation
- Conservative defaults
- Repository command declarations
- Autonomy restrictions
- Verification requirements
- Budget declarations
- Actionable validation failures
- Platform policy precedence

## Completion gate

M2 is complete only when:

- Issues #2 and #3 are merged.
- Durable task authority exists outside worker or model memory.
- Every legal state transition is explicit and tested.
- Illegal transitions are rejected.
- Duplicate requests are idempotent.
- Restart state can be reconstructed from durable storage.
- A repository manifest can be validated without executing commands or mutating the repository.
- Repository configuration cannot expand platform authority.
- All required CI checks pass.

## Prohibited during M2

Do not implement:

- Live GitHub issue ingestion
- GitHub App authentication
- Webhook processing
- Outbox delivery
- Coding-agent execution
- Symphony scheduler integration
- Workspace execution
- Sandbox runtime
- Pull-request creation
- Independent verifier execution
- Repair agents
- Multi-repository scheduling
- Second agent backend
- Dashboard or operator UI
- Production deployment

## Current status

**Complete.**

## Durable completion record

M2 completion is evidenced by merged Issue #2 / [PR #10](https://github.com/kool1160/sxf-core/pull/10)
and completed Issue #3 / [PR #13](https://github.com/kool1160/sxf-core/pull/13). The required
repository CI checks passed for both changes, including formatting, dependency audit, warning-free
compilation, and the test suite.

# M3 — First Autonomous Vertical Slice

## Goal

Prove one complete execution loop against one designated disposable test repository.

## Status

**Active.**

## Required flow

```text
GitHub issue marked ready
→ persisted SXF task
→ isolated workspace and branch
→ one coding-agent backend
→ repository-defined deterministic checks
→ commit and pull request
→ structured evidence
→ durable final task state
```

## Completion gate

M3 is complete only when SXF can repeatedly:

1. Register one test repository using a validated manifest.
2. Ingest one scoped issue without manual copying between systems.
3. Persist the task and attempt.
4. Survive a control-plane restart.
5. Create an isolated workspace and branch.
6. Run one coding-agent backend.
7. Execute repository-defined commands.
8. Capture commands, output, exit status, runtime, usage, and evidence.
9. Open a pull request after successful deterministic checks.
10. Produce explicit blocked or failed outcomes for unsuccessful work.
11. Enforce runtime and cost budgets.
12. Replay intake without creating duplicate work.
13. Repeat the demonstration from documented setup instructions.

## Prohibited during M3

Do not implement:

- Independent model-based verification
- Automated repair based on verifier findings
- Automatic merge
- Production deployment
- Multiple repositories
- Second coding-agent backend
- Model-routing optimization
- Full dashboard
- Distributed workers
- High-availability control plane

# M4 — Independent Verification and Repair

## Goal

Prevent builders from declaring their own work correct and repair ordinary defects without routine human intervention.

## Required flow

```text
builder attempt
→ deterministic checks
→ independent verifier
→ APPROVED or CHANGES_REQUESTED
→ bounded repair attempt
→ deterministic checks
→ independent re-verification
```

## Completion gate

M4 is complete only when:

- Builder and verifier are operationally separate.
- The verifier receives the original task and acceptance criteria.
- The verifier receives the diff and deterministic evidence.
- Failed deterministic checks cannot be overridden by model judgment.
- Findings are structured and reproducible.
- Findings map to acceptance criteria.
- Repair attempts have explicit cost, runtime, and retry limits.
- Repeated disagreement escalates explicitly.
- Approval records its supporting evidence.
- A seeded defect is detected and repaired successfully.
- An unrepairable defect reaches an explicit blocked or failed result.

## Prohibited during M4

Do not implement:

- Multiple connected repositories
- Second coding-agent backend
- Cross-project scheduling
- Full operator dashboard
- Production deployment automation
- Distributed execution
- High availability

# M5 — Multiple Repositories and Replaceable Agent Backends

## Goal

Generalize the verified loop without weakening isolation or making a provider authoritative.

## Completion gate

M5 is complete only when:

- Multiple repositories can be registered independently.
- Every task, attempt, event, workspace, and evidence record carries project identity.
- Repository and global concurrency limits are enforced separately.
- At least two coding-agent backends implement the same stable contract.
- Core orchestration contains no backend-specific workflow authority.
- Backend selection can use explicit policy and measured outcomes.
- Repository credentials, workspaces, secrets, and permissions remain isolated.
- One backend can fail or be disabled without corrupting unrelated work.
- Cross-project leakage tests pass.

## Prohibited during M5

Do not implement:

- A dashboard as the workflow authority
- Unbounded model routing
- Production auto-deployment
- Distributed workers without measured need
- High-availability infrastructure without measured need

# M6 — Operator Controls, Cost Tracking, and Auditability

## Goal

Make SXF understandable and controllable without reading raw worker logs or mutating state outside the domain model.

## Completion gate

M6 is complete only when:

- Operators can view projects, tasks, attempts, blockers, evidence, and active work.
- Operators can pause, resume, cancel, retry, approve, and escalate through legal state transitions.
- Cost, usage, runtime, retries, and intervention are recorded.
- Metrics exist per attempt, task, project, and backend.
- Every material action records actor, timestamp, reason, correlation, and evidence.
- Hidden retries and hidden recovery are impossible.
- Budget warnings and hard stops are visible and enforced.
- Audit records are append-oriented and protected from ordinary workers.
- Reports include:
  - Cost per accepted result
  - First-pass acceptance rate
  - Repair cycles
  - Escaped defects
  - Human intervention rate

## Prohibited during M6

Do not claim safe unattended production operation.

Do not add distributed or high-availability infrastructure unless measured load proves it necessary.

# M7 — Safe Unattended Operation

## Goal

Prove SXF can operate for extended periods without hiding failure, leaking authority, corrupting state, or claiming unsupported success.

## Completion gate

M7 is complete only when:

- Restart and crash recovery are tested.
- Duplicate and out-of-order events are tested.
- Stale workspace and stale lease recovery are tested.
- Partial external failures are tested.
- Repository, filesystem, secret, network, and deployment permissions follow least privilege.
- Destructive and production-facing actions require explicit policy and authority.
- Dependency and infrastructure failures degrade safely.
- Long-running soak tests cover mixed workloads.
- Recovery is observable and auditable.
- Backup and restoration of authoritative state are tested.
- Upgrade and rollback procedures are exercised.
- Release readiness records:
  - Known limitations
  - Intervention rate
  - Cost per accepted result
  - Failure and recovery rates
  - Unresolved security and reliability risks

## Result

Only after M7 may SXF be described as ready for extended unattended operation.

# Mandatory work-selection check

Before recommending, creating, or beginning any issue, every human or agent must answer:

1. What is the active milestone?
2. Which active-milestone acceptance criterion does this work satisfy?
3. Is this required to pass the current completion gate?
4. Does it implement functionality assigned to a later milestone?
5. Could it be deferred without blocking the current milestone?
6. What evidence will prove it complete?
7. What is explicitly out of scope?
8. What budget and retry limits apply?

If the work does not clearly satisfy the active milestone, do not begin it.

Record it as deferred work instead.

# Mandatory review check

Every pull-request review must determine:

- Whether the PR belongs to the active milestone
- Whether it silently expands scope
- Whether it introduces later-milestone functionality
- Whether success claims are supported by evidence
- Whether authoritative state remains durable
- Whether deterministic failures remain authoritative
- Whether permissions increased
- Whether human babysitting is being hidden
- Whether the milestone gate is actually closer to completion

A technically correct change may still be rejected for violating milestone order.

# Current execution sequence

```text
M1 Symphony Foundation
    COMPLETE
        ↓
M2 Durable Core
    COMPLETE
        ↓
M3 First Autonomous Vertical Slice
    ACTIVE
        ↓
M4 Independent Verification and Repair
        ↓
M5 Multiple Repositories and Replaceable Backends
        ↓
M6 Operator Controls, Cost Tracking, and Auditability
        ↓
M7 Safe Unattended Operation
```

No milestone may be skipped.

No later milestone may be used to conceal failure in an earlier milestone.

No milestone is complete without merged evidence.

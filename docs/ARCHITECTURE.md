# Architecture

## Architectural objective

SXF is a reusable control plane for autonomous software execution across multiple repositories. The central platform owns orchestration, policy, state, execution adapters, evidence, and observability. Connected repositories own their product requirements, commands, acceptance criteria, and project-specific restrictions.

## High-level system

```text
GitHub / Operator / API
          ↓
   Intake and normalization
          ↓
   Orchestrator + state machine
          ↓
 Policy engine + scheduler + budgets
          ↓
 Workspace manager / sandbox runtime
          ↓
 Agent backend + capability packs
          ↓
 Deterministic checks and evidence
          ↓
 Independent verifier / repair loop
          ↓
 GitHub PR / staging / release decision
```

## Major components

### Control plane

The authoritative coordinator. It persists project registrations, task state, attempts, transitions, budgets, evidence references, and outcomes. It must remain deterministic wherever possible and must not rely on a model to remember workflow state.

### Project registry

Maps each connected repository to a validated project manifest, enabled capabilities, trust level, autonomy policy, secret scope, and execution environment.

### Intake adapter

Converts GitHub issues, operator requests, or approved specifications into a normalized task contract. Intake may use a model for analysis, but the resulting task must be explicit and persisted.

### State machine

Controls legal task transitions and prevents conversational drift. State changes must be idempotent, auditable, and attributable.

Initial states:

```text
DISCOVERED
SPECIFIED
PLANNED
READY
IMPLEMENTING
CI_RUNNING
VERIFYING
CHANGES_REQUESTED
APPROVED
STAGING
RELEASE_READY
DEPLOYED
BLOCKED
FAILED
CANCELLED
```

The exhaustive legal edges, preconditions, terminal/reopen rules, and durable record contract are
defined in [`TASK_DOMAIN.md`](TASK_DOMAIN.md). `BLOCKED` is nonterminal; `FAILED` and `CANCELLED`
are terminal until an explicit approved reopen; `DEPLOYED` is permanently terminal.

### Scheduler

Selects ready work while respecting repository concurrency, dependencies, rate limits, cost budgets, workspace capacity, and conflicting file or subsystem ownership.

### Workspace manager

Creates a clean, isolated workspace for each attempt. A workspace contains only the repository state, scoped credentials, tools, and network access required for the task.

### Agent backend adapter

Provides a stable interface over coding-agent runtimes and model providers. The control plane must not depend directly on one vendor's conversation model or tool protocol.

A backend should support:

- Start, resume, cancel, and inspect execution.
- Stream structured events.
- Report token, time, and monetary usage.
- Enforce tool and workspace boundaries.
- Return an explicit result and evidence references.

### Capability packs

Reusable stack-specific knowledge and operations, such as Python/FastAPI, TypeScript/Next.js, .NET, PostgreSQL, Playwright, Docker, or Vercel. Capability packs supplement permanent agent roles and project-specific instructions.

### Deterministic gate runner

Runs repository-defined install, lint, type-check, test, build, scan, and validation commands. Its results are authoritative inputs to verification.

### Independent verifier

Evaluates the original task and acceptance criteria against the code, deterministic results, and running application. The verifier should be isolated from the builder's reasoning and may use a different model family or backend.

### Repair coordinator

Transforms verification failures into scoped repair instructions, increments attempt budgets, and returns work to implementation without discarding useful state.

### GitHub integration

A GitHub App should provide repository-scoped identity, webhook intake, issue and pull-request operations, status reporting, and installation-based permissions. Personal access tokens should not be the permanent platform identity.

### Evidence store

Stores structured results and references to logs, test output, screenshots, videos, traces, diffs, scan reports, and deployment observations. Evidence must be tied to a task attempt and immutable after finalization.

### Operator interface

Shows projects, active tasks, state, budgets, failures, evidence, required decisions, and release readiness. The dashboard is an operational surface, not the source of workflow truth.

## Project manifest

Each connected repository provides a versioned manifest validated by `schemas/project.schema.json`.
It declares commands, requested autonomy, verification requirements, budgets, protected paths, and
prohibited actions. [`PROJECT_MANIFEST.md`](PROJECT_MANIFEST.md) defines pure YAML/JSON loading,
normalization, actionable failures, and platform-policy precedence. Repository autonomy and network
requests are intersected with a platform-owned ceiling; restrictions are additive and cannot weaken
platform prohibitions.

The manifest supplements rather than replaces repository documentation. Commands and policy must be explicit enough that a clean worker can reproduce them.

## Event model

Components communicate through durable events rather than direct conversational handoffs. Example event types:

- `project.registered`
- `task.discovered`
- `task.ready`
- `attempt.started`
- `agent.event.recorded`
- `checks.completed`
- `verification.completed`
- `repair.requested`
- `pull_request.opened`
- `deployment.completed`
- `task.blocked`

Events must carry stable project, task, attempt, actor, and correlation identifiers.

The Phase 1 implementation uses UUID strings for these identifiers and an append-oriented
transition ledger with an atomically updated current-state projection. Tracker and agent-session
identifiers are opaque references, never authoritative task IDs.

## Data boundaries

SXF platform data:

- Project registrations and policies.
- Task and attempt state.
- Agent events and usage.
- Evidence metadata.
- Audit records.

Connected repository data:

- Product and architecture documents.
- Source code and tests.
- Project commands and acceptance criteria.
- Repository-specific agent instructions.

## Initial deployment shape

The first vertical slice should run locally in containers against one test repository. It should avoid premature distributed-system complexity while preserving interfaces that allow later separation of the control plane, queue, worker pool, and evidence store.

## Decisions intentionally deferred

The following choices require an architecture decision record before implementation:

- Durable queue technology beyond the Phase 1 SQLite retry/outbox records.
- Sandbox implementation beyond the Linux-container boundary selected in ADR 0002.
- A second coding-agent backend after the Codex adapter selected in ADR 0002.
- First verifier model/backend.
- GitHub App hosting model.
- Observability stack.

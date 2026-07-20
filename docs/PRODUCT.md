# Product Definition

## Product name

**SXF — Software Xecution Factory**

## Problem

Modern coding agents can implement isolated tasks, but reliable autonomous software delivery still requires humans to repeatedly provide context, approve routine actions, inspect self-reported success, restart failed work, coordinate GitHub activity, and verify whether the application actually works.

Most agent systems are optimized around completing a coding session. SXF is optimized around delivering an accepted, working result across many repositories.

## Vision

A repository owner should be able to connect a project, provide an idea, specification, or issue, and allow SXF to carry the work through planning, implementation, deterministic testing, independent verification, repair, pull-request management, and staging with humans involved primarily for genuine product decisions and exceptional risk.

## Primary users

- Individual builders managing several applications.
- Small engineering teams seeking autonomous issue execution.
- Organizations that require auditable, policy-controlled agent work.
- Operators comparing models and runtimes by accepted result rather than benchmark marketing.

## Core goals

1. Support multiple independent GitHub repositories from one reusable control plane.
2. Keep project-specific truth and commands inside each connected repository.
3. Execute each task in an isolated workspace.
4. Use deterministic checks before model-based review.
5. Require independent verification for meaningful changes.
6. Automatically repair ordinary failures within bounded budgets.
7. Escalate only when human judgment or authority is genuinely required.
8. Track cost, time, retries, evidence, and outcomes per task.
9. Allow model providers and coding-agent runtimes to be replaced without redesigning the platform.
10. Produce maintainable software and durable project documentation.

## Non-goals

- Pretending every software decision can be made without a human.
- Maximizing the number of agents involved in a task.
- Allowing agents unrestricted access to machines, secrets, networks, or production systems.
- Replacing deterministic tests with agent opinion.
- Supporting every technology stack in the first release.
- Building a general-purpose chat interface before the execution loop works.
- Selecting the cheapest model regardless of failure rate or rework cost.

## Core product capabilities

### Repository onboarding

- Install or authorize SXF for selected repositories.
- Inspect an existing repository and propose a project manifest.
- Initialize an empty repository from a specification.
- Validate repository commands, policies, and required documentation.

### Work intake

- Accept GitHub issues, approved specifications, and operator-created tasks.
- Normalize work into scoped tasks with acceptance criteria.
- Identify dependencies and safe parallelism.

### Execution

- Create an isolated branch and workspace.
- Select an agent backend and capability packs.
- Implement the task within budget and permission constraints.
- Persist progress and recover from restarts.

### Verification

- Run repository-defined deterministic checks.
- Independently verify acceptance criteria.
- Collect machine-readable evidence and user-facing proof where applicable.
- Return failed work to a bounded repair loop.

### GitHub operations

- Create and update issues, branches, commits, pull requests, labels, and reviews.
- Observe CI and deployment state.
- Merge only when policy gates are satisfied.

### Operations

- Display task state, costs, retries, blockers, and evidence.
- Pause or cancel work safely.
- Audit every consequential action.

## Success metrics

SXF should be evaluated using:

- Accepted pull requests per dollar.
- First-pass deterministic-check success rate.
- Independent-verification pass rate.
- Human intervention rate.
- Repair cycles per accepted task.
- Escaped defects after merge.
- Median time from ready task to verified pull request.
- Percentage of failures recovered without human action.
- Cost and quality by model, backend, repository, and task class.

## Product principle

The unit of value is not a model call, an agent turn, a commit, or a pull request. The unit of value is a verified result that satisfies the repository's acceptance criteria without introducing unacceptable risk.

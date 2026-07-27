# SXF — Software Xecution Factory

SXF is a reusable autonomous software development platform designed to turn application ideas, specifications, and GitHub issues into tested, verified, and maintainable software with minimal human intervention.

SXF coordinates specialized agents for project planning, architecture, coding, GitHub operations, testing, debugging, independent verification, and release management. Each connected repository supplies its own project requirements, technology stack, commands, policies, and acceptance criteria, while the central SXF platform provides the reusable orchestration, agent roles, workflows, safeguards, and execution infrastructure.

The goal is not to produce the cheapest possible code or maximize agent activity. The goal is to produce accurate, working software at a reasonable cost, with humans involved primarily for genuine product decisions, exceptions, destructive actions, and final production authority.

## Core principles

- **Reusable by design** — one control plane can operate across many repositories and technology stacks.
- **Human on exception** — routine work proceeds autonomously; humans handle ambiguity, risk, and product judgment.
- **Independent verification** — the system does not accept a builder's claim that its own work is correct.
- **Evidence over confidence** — tests, checks, logs, screenshots, and acceptance criteria determine whether work passes.
- **Deterministic gates first** — CI, type checks, linters, security scans, and policy checks outrank agent opinion.
- **Cost per accepted result** — optimize for reliable completed work, not the cheapest individual model call.
- **Provider-neutral architecture** — agent runtimes and model providers should be replaceable behind stable interfaces.
- **Repository-owned truth** — project requirements, commands, policies, and acceptance criteria live with the project.

## Intended workflow

```text
Idea / Specification / GitHub Issue
                ↓
        Planning and task graph
                ↓
      Isolated implementation work
                ↓
      Deterministic CI and testing
                ↓
       Independent verification
                ↓
      Repair loop when required
                ↓
      Pull request and staging
                ↓
        Release-ready decision
```

## Planned platform areas

- Control plane and state machine
- Project and repository registry
- GitHub App integration
- Agent-role definitions
- Replaceable agent backends
- Isolated workspaces and sandboxes
- Capability packs for technology stacks
- Verification and evidence collection
- Policy, budget, retry, and escalation controls
- Observability, cost tracking, and audit logs
- Operator dashboard

## Repository status

SXF is implementing M3, the first autonomous vertical slice, after completing M1 and M2. The
repository now contains the initial Elixir/OTP,
Ecto, and SQLite WAL task domain: stable identities, an explicit lifecycle, transactional transition
history, attempts, budgets, retries, leases, blockers, decisions, and evidence references. A
durable execution coordinator now atomically claims eligible tasks, invokes provider-neutral fake
agent/workspace/sandbox backends, persists fenced events and usage, enforces limits, and reconciles
interrupted attempts without starting Symphony as a competing authority. It also
loads, strictly validates, normalizes, and applies platform policy ceilings to version `0.1` YAML or
JSON connected-project manifests without executing their commands. It does not yet contain the
live agent, GitHub App, repository, or container execution, container workspace
runtime, or evidence byte store. The pinned Symphony Elixir foundation is retained under
`upstream/openai-symphony` as a compile-time, default-denied path dependency; it is not started and
does not replace SXF's durable task authority.

See [`AGENTS.md`](AGENTS.md) for repository guidance, [`docs/TASK_DOMAIN.md`](docs/TASK_DOMAIN.md)
for the durable lifecycle contract, [`docs/PROJECT_MANIFEST.md`](docs/PROJECT_MANIFEST.md) for the
manifest validation contract, [`docs/UPSTREAM_SYMPHONY.md`](docs/UPSTREAM_SYMPHONY.md) for the
upstream boundary, [`docs/EXECUTION_COORDINATOR.md`](docs/EXECUTION_COORDINATOR.md) for the M3
coordinator contract, and [`docs/`](docs/) for broader product, architecture, reliability, security,
and roadmap documents.

## Durable-core checks

The current application requires Erlang/OTP 28 and Elixir 1.19. From the repository root:

```text
mix deps.get
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix test
```

`mix test` creates and migrates the ignored test database. Production requires an explicit
`SXF_DATABASE_PATH`.

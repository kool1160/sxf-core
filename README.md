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

SXF is in the foundation and architecture phase. The initial repository structure defines the product boundaries, operating principles, and implementation roadmap before framework-specific code is introduced.

See [`AGENTS.md`](AGENTS.md) for repository guidance and [`docs/`](docs/) for the product, architecture, reliability, security, and roadmap documents.

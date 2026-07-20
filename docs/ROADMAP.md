# Roadmap

The roadmap is organized around working vertical slices. SXF should prove one reliable execution loop before expanding the number of agents, providers, stacks, or dashboards.

## Phase 0 — Foundation

- Establish product, architecture, security, reliability, and contribution contracts.
- Define the connected-project manifest schema.
- Select the first implementation stack through an architecture decision record.
- Define measurable acceptance criteria for the first vertical slice.

## Phase 1 — Single-repository vertical slice

Goal: take one well-specified GitHub issue in a test repository from `READY` to a pull request with deterministic evidence.

- Local control-plane service.
- Durable task and attempt state.
- GitHub issue intake.
- One isolated workspace at a time.
- One coding-agent backend.
- Repository command execution.
- Branch, commit, and pull-request creation.
- Structured logs and cost recording.

## Phase 2 — Independent verification and repair

Goal: reject incorrect work automatically and repair ordinary failures without human intervention.

- Acceptance-criterion contract.
- Independent verifier.
- Evidence model.
- Bounded repair loop.
- Failure classification.
- Human escalation package.

## Phase 3 — Multi-repository operation

Goal: operate several repositories without context or credential leakage.

- Project registry.
- GitHub App installation management.
- Per-project policies and secrets.
- Repository concurrency controls.
- Scheduler and dependency handling.
- Cross-project isolation tests.

## Phase 4 — Provider and capability portability

Goal: compare and replace execution backends without changing orchestration semantics.

- Stable agent-backend interface.
- Second coding-agent backend.
- Capability-pack contract.
- Initial web, API, and desktop capability packs.
- Model routing by task class and measured outcomes.

## Phase 5 — Staging and operator experience

Goal: provide useful operational control without making the dashboard the workflow engine.

- Staging deployment adapter.
- Browser-based acceptance evidence.
- Project/task dashboard.
- Pause, resume, cancel, and approve controls.
- Cost, intervention, and quality reports.

## Phase 6 — Hardening

- Distributed workers where justified by measured load.
- High-availability control plane.
- Stronger sandbox and network isolation.
- Security review and threat-model validation.
- Backup and disaster recovery.
- Versioned workflow and manifest migrations.
- Production-release policies.

## First milestone definition

The first milestone is complete when SXF can repeatedly:

1. Read a scoped issue from a designated test repository.
2. Create an isolated branch and workspace.
3. Run one coding-agent backend.
4. Execute repository-defined checks.
5. Open a pull request containing the change and evidence.
6. Persist enough state to recover safely after a process restart.
7. Stop within configured time and cost budgets.

Independent verification is the following milestone, not a fake checkbox in the first one.

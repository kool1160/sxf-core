# AGENTS.md

This file is the entry point for human and automated contributors working in the SXF repository.

## Mission

Build a reusable, multi-repository Software Xecution Factory that can plan, implement, test, independently verify, and manage software work with minimal human supervision.

SXF must optimize for accurate, maintainable, accepted results at a reasonable cost. It must not optimize for agent activity, impressive demos, or the cheapest individual model call.

## Sources of truth

Read these documents before making architectural or behavioral changes:

1. [`docs/PRODUCT.md`](docs/PRODUCT.md) — product goals, users, requirements, and non-goals.
2. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — system boundaries and component responsibilities.
3. [`docs/TASK_DOMAIN.md`](docs/TASK_DOMAIN.md) — durable records, legal transitions, and recovery semantics.
4. [`docs/PROJECT_MANIFEST.md`](docs/PROJECT_MANIFEST.md) — connected-project loading, normalization, and policy precedence.
5. [`docs/SECURITY.md`](docs/SECURITY.md) — trust boundaries and prohibited behavior.
6. [`docs/RELIABILITY.md`](docs/RELIABILITY.md) — evidence, retries, idempotency, and failure handling.
7. [`docs/ROADMAP.md`](docs/ROADMAP.md) — implementation sequence.
8. [`schemas/project.schema.json`](schemas/project.schema.json) — connected-project manifest contract.

When documents conflict, stop and surface the conflict rather than silently choosing the easiest interpretation.

## Operating rules

- Never push implementation work directly to `main` once branch protection is enabled.
- Work from a scoped issue with explicit acceptance criteria.
- Keep one concern per branch and pull request.
- Do not declare success based on agent confidence or a clean-looking diff.
- Record evidence: commands run, tests passed, observed behavior, and unresolved risks.
- Treat deterministic checks as authoritative. Agent review cannot override failed CI.
- The builder must not be the sole verifier of its own work.
- Keep model providers and agent runtimes behind replaceable adapters.
- Keep project-specific instructions in the connected repository, not hard-coded into SXF.
- Do not expose secrets, weaken security controls, or expand permissions to make a task easier.
- Avoid destructive or production-facing actions without an explicit policy or human approval.
- Do not fabricate test results, command output, repository state, citations, or completion claims.

## Standard task lifecycle

```text
DISCOVERED
→ SPECIFIED
→ PLANNED
→ READY
→ IMPLEMENTING
→ CI_RUNNING
→ VERIFYING
→ CHANGES_REQUESTED | APPROVED
→ STAGING
→ RELEASE_READY
→ DEPLOYED | FAILED | BLOCKED | CANCELLED
```

Every state transition must be persisted and attributable to an event, policy decision, or verified result.
The exhaustive lifecycle contract, including repair, block/resume, cancellation, failure, and reopen
edges, is [`docs/TASK_DOMAIN.md`](docs/TASK_DOMAIN.md).

## Human escalation conditions

Escalate when:

- Product requirements are materially ambiguous or contradictory.
- A destructive or irreversible action is requested.
- Production data, billing, authentication policy, legal obligations, or privacy decisions are involved.
- Retry, runtime, or cost budgets are exhausted.
- Builder and verifier repeatedly disagree.
- Required evidence cannot be collected.
- A security boundary would need to be weakened.

## Repository map

- `docs/` — durable product and engineering truth.
- `schemas/` — versioned machine-readable contracts.
- `examples/` — valid example configurations.
- `.github/` — contribution and workflow metadata.
- Future source directories must follow the architecture decision records and should not be created merely to imply progress.

## Current phase

SXF is in the foundation phase. Do not lock the repository into a language, framework, queue, database, or cloud provider until the first vertical-slice architecture decision is documented.

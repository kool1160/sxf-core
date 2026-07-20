# ADR 0001: Separate the reusable control plane from connected-project truth

- **Status:** Accepted
- **Date:** 2026-07-20

## Context

SXF must operate across unrelated repositories and technology stacks. Hard-coding project requirements, commands, deployment assumptions, or model-provider behavior into permanent agents would make the system brittle and non-reusable.

## Decision

SXF will separate:

1. **Platform-owned behavior** — orchestration, state, policy, scheduling, budgets, adapters, isolation, evidence, and audit.
2. **Repository-owned truth** — product requirements, architecture constraints, commands, acceptance criteria, protected paths, and autonomy policy.
3. **Replaceable execution capabilities** — coding-agent backends, model providers, sandbox runtimes, and technology capability packs.

Connected repositories will expose a versioned manifest plus durable documentation. The platform will validate this information during onboarding and before execution.

## Consequences

### Positive

- One SXF installation can operate many projects.
- Provider and stack changes do not require redesigning the control plane.
- Project behavior remains reviewable and versioned with the code.
- Agents receive focused context rather than one global prompt.

### Negative

- Contracts and adapters require careful versioning.
- Onboarding must validate project configuration.
- Some behavior cannot be inferred automatically and must be declared.

## Guardrail

No implementation may make one project's name, framework, commands, or deployment provider a permanent assumption of the core orchestration layer.

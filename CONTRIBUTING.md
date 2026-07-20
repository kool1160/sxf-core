# Contributing to SXF

SXF is being built as an execution platform, so changes should improve measurable system behavior rather than merely add agent roles or abstraction layers.

## Before starting

1. Read `AGENTS.md` and the relevant documents in `docs/`.
2. Open or select a GitHub issue with acceptance criteria.
3. Identify affected trust boundaries, state transitions, and failure modes.
4. Keep the proposed change as small as practical.

## Pull requests

A pull request should include:

- The problem being solved.
- The implementation approach.
- Acceptance criteria and evidence for each criterion.
- Tests and commands executed.
- Security, reliability, migration, and rollback considerations.
- Known limitations or follow-up work.

A pull request is not ready merely because code was generated. It is ready when its behavior is demonstrated and independently reviewable.

## Design changes

Create an architecture decision record in `docs/decisions/` when a change:

- Selects or replaces a major framework or provider.
- Changes a durable public contract.
- Changes state-machine semantics.
- Changes permission, sandbox, or secret boundaries.
- Introduces a significant operational dependency.

## Commit style

Use concise imperative commit messages. Conventional prefixes are encouraged:

- `feat:` new behavior
- `fix:` corrected behavior
- `docs:` documentation only
- `test:` test changes
- `refactor:` behavior-preserving restructuring
- `chore:` repository or tooling maintenance
- `security:` security hardening

# OpenAI Symphony upstream boundary

This document defines the auditable import boundary selected for GitHub Issue #17. It must be read
with ADR 0002 and ADR 0004 before importing or upgrading Symphony.

## Import method

SXF vendors the pinned OpenAI Symphony Elixir application as a Git subtree rooted at
`upstream/openai-symphony/elixir`. The subtree is sourced from
`openai/symphony@633eae740f807de18007f5a9a25e2e0d206afdf4`. Root upstream material required to
understand and license that application is retained beside it: `SPEC.md`, `LICENSE`, and `NOTICE`.

The complete Elixir application is retained because its Mix project, core scheduler, tracker
adapters, Codex protocol client, optional observability components, and conformance tests form one
upstream release unit. Pruning individual modules would require a broad rewrite of the upstream
Mix project and application supervision tree, obscuring rather than reducing the security and
upgrade diff. Non-Elixir website, marketing media, repository skills, release automation, and root
examples are not imported.

Every retained file is listed in `upstream/openai-symphony/import-manifest.json` with its original
path and Git blob, imported path and SHA-256, license, modification state, and required notice
state. `scripts/verify_symphony_import.exs` retains an offline mode that checks the imported index,
hashes, modification declarations, markers, license, and NOTICE against that manifest. Required
Linux CI also fetches the public pinned commit into a separate checkout and resolves
`633eae740f807de18007f5a9a25e2e0d206afdf4:<upstreamPath>` for every entry. The verifier compares
each independently resolved Git blob to `upstreamGitBlobSha`, so coordinated drift of an imported
file and its manifest entry cannot pass the authoritative check. A modified upstream file carries
an SXF modification notice identifying the upstream repository, pinned commit, and original path.

This method is safer than flattening modules into `lib/sxf`: the Apache-2.0 code remains visibly
separate from proprietary SXF code, upstream file paths stay stable, blob identity remains
comparable, and upgrades can be reviewed as dedicated subtree/provenance changes.

## Runtime quarantine

The vendored Mix project is a compile-time path dependency with `runtime: false`. SXF does not add
`SymphonyElixir.Application`, `SymphonyElixir.AgentRuntimeSupervisor`, or
`SymphonyElixir.Orchestrator` to its supervision tree in this import. SQLite task state and
`task_transition_events` therefore remain the sole workflow authority.

Two upstream behaviors are additionally default-denied inside the vendored boundary:

- repository-owned workspace hooks cannot execute unless an integrating SXF runtime explicitly
  enables them after establishing the Linux-container worker boundary; and
- provider-native agent tools, including the broad `github_api` surface, are neither advertised nor
  executed unless explicitly enabled by a later policy-checked integration.

Those switches are defense in depth, not authorization for later work. Issue #17 does not add
GitHub App credentials, live issue intake, agent execution, workspace population, external
mutation, pull-request creation, independent verification, or repair.

## Dependency policy

The upstream lock at the pinned commit contains known advisories and conflicts with SXF's Decimal
3 durable monetary domain. The vendored Mix and lock files therefore carry modification notices.
Only dependency constraints and resolved pins needed for integrated compilation and a clean
`mix hex.audit` are changed. The import manifest records both files as modified; the pull request
must describe exact version changes and conformance evidence.

## Upgrade procedure

1. Open a dedicated upgrade issue and pin the proposed upstream commit.
2. Review the upstream specification, Elixir source, tests, dependencies, license, and NOTICE diff.
3. Update the subtree without flattening or renaming upstream paths.
4. Reapply the smallest SXF patch series and retain compliant modification notices.
5. Regenerate the import manifest, run its offline checks, and verify every entry against a fresh
   fetch of the pinned public upstream commit.
6. Run license/NOTICE verification, the selected upstream conformance profile, full SXF checks,
   dependency audit, and Linux CI.
7. Record semantic changes, deferred integration work, and unresolved risks in the upgrade pull
   request. Never auto-merge upstream `main`.

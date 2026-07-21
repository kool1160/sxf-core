# Connected-project manifest validation

This document is the normative loading and validation contract for the `0.1` connected-project
manifest defined by [`schemas/project.schema.json`](../schemas/project.schema.json). It implements
GitHub Issue #3 within M2. It does not onboard a repository, execute a command, create a workspace,
or persist project state.

## File contract

`Sxf.ProjectManifest.load/2` accepts one UTF-8 `.yaml`, `.yml`, or `.json` file of at most 1 MiB.
`load_string/3` accepts decoded source in either format. YAML is parsed with string keys and atom
conversion disabled; JSON is decoded to the same string-keyed representation. The parsed value is
validated against the embedded Draft 2020-12 schema before any normalization occurs.

Source size is not the only parser boundary. Decoding runs in a monitored process with a 5-second
time limit and a bounded heap. The decoded value may contain at most 64 nested containers, 10,000
total nodes, and 2,000 containers. These limits are checked before schema traversal and again at
the public decoded-value boundary. YAML anchors, aliases, and merge references are rejected before
parsing; manifests must duplicate a bounded value explicitly. Anchor-like text remains valid inside
quoted YAML scalars.

The manifest must explicitly declare `schemaVersion: "0.1"`. An unsupported version returns an
`unsupported_version` error at `/schemaVersion`; it is never interpreted as the nearest known
version. Unknown file extensions, malformed syntax, multiple YAML documents, duplicate properties,
YAML references, excessive decoded structures, unknown properties, invalid values, and missing
required properties return structured `%Sxf.ProjectManifest.Error{}` values containing a stable
code, JSON Pointer path, and human-readable message.

The schema is closed at every object boundary, including `commands`. Repository configuration
therefore cannot introduce credential, sandbox, approval-bypass, or arbitrary command fields that
the platform does not understand.

## Required declarations

The `0.1` contract requires:

- project name, description, and greenfield/existing status;
- non-empty `install` and `test` commands;
- explicit branch, pull-request, default-branch merge, and production-deployment autonomy requests;
- independent-verification and deterministic-check requirements; and
- positive cost, runtime, and agent-turn budgets plus a bounded repair-cycle budget.

Optional commands are accepted only when non-empty. Optional values receive these stable defaults:

| Path | Default |
| --- | --- |
| `/project/documentationRoot` | `docs` |
| `/autonomy/createIssues` | `false` |
| `/autonomy/deployToStaging` | `false` |
| `/verification/requireDifferentBackend` | `false` |
| `/verification/requireUiEvidence` | `false` |
| `/restrictions` and each restriction list | empty |

No default grants authority, network access, or permission to mutate a repository.

## Normalized result

Successful validation returns `%Sxf.ProjectManifest{}` with fixed fields and keys. It separates:

- `requested_autonomy` — what the repository requested; and
- `autonomy` — the effective request after applying the platform ceiling.

Commands remain inert strings. Optional defaults are materialized. Restriction arrays are sorted
and deduplicated so equivalent YAML and JSON inputs produce a stable representation.

Repository `maxCostUsd` is converted to `budgets["maxCostMicrousd"]`, the durable task domain's
integer monetary unit. Conversion multiplies the exact parsed decimal by 1,000,000 and floors any
fractional microusd. It never rounds a repository budget upward. The normalized budget does not
retain the floating USD value.

## Platform policy precedence

`Sxf.ProjectManifest.Policy` is platform-owned. Its default grants no autonomy and no outbound
network domains. It owns explicit budget ceilings and verification minima. A manifest that exceeds
an authority, network, budget, or verification boundary fails onboarding with a
`platform_policy_conflict` at the repository field that requested it; validation never silently
clips an over-authority request and reports success.

The default platform budget ceilings are:

| Policy field | Default ceiling |
| --- | ---: |
| `max_cost_microusd` | 15,000,000 ($15) |
| `max_runtime_minutes` | 120 |
| `max_agent_turns` | 80 |
| `max_repair_cycles` | 3 |

Effective policy is computed conservatively after every request has passed those checks:

- every requested autonomy action must be platform-allowed;
- every requested network domain must be in the platform allowlist;
- repository cost, runtime, agent-turn, and repair-cycle budgets must be at or below the platform
  ceilings;
- platform-required `independent`, `requireDeterministicChecks`, `requireDifferentBackend`, and
  `requireUiEvidence` gates must be `true`;
- repository `minimumCoveragePercent` must be at least the platform minimum when configured;
- protected paths are the union of repository and platform paths;
- prohibited actions are the union of repository, platform, and mandatory platform prohibitions;
  and
- accepted allowed network domains are preserved unchanged.

Independent verification and deterministic checks are mandatory platform verification gates.
The default platform minimum coverage is zero and the optional different-backend and UI-evidence
gates default to false; a configured platform policy may raise any of these requirements. A
repository may require stricter verification or lower budgets, but never weaker verification or
higher budgets.
Mandatory platform prohibitions include production-data deletion, production deployment, secret
exposure, billing modification, and weakening branch protection. Callers cannot remove these gates
or prohibitions when constructing a platform policy. Consequently, a repository request cannot
broadly weaken verification, authority, credential boundaries, sandbox policy, or network policy.
This validation result is an input to later policy enforcement, not authorization to perform an
action.

Example:

```elixir
policy =
  Sxf.ProjectManifest.Policy.new(
    allowed_autonomy: ["createBranches", "openPullRequests"],
    allowed_network_domains: ["github.com"],
    required_verification: ["requireDifferentBackend", "requireUiEvidence"],
    minimum_coverage_percent: 80,
    max_cost_microusd: 10_000_000,
    max_runtime_minutes: 60,
    max_agent_turns: 40,
    max_repair_cycles: 2
  )

Sxf.ProjectManifest.load("project.sxf.yaml", platform_policy: policy)
```

## Safety boundary

Validation performs only bounded file metadata/read operations, isolated parsing, decoded-structure
checks, schema validation, policy validation, and pure normalization. It never:

- invokes a shell or any declared command;
- writes to the connected repository;
- installs dependencies from the manifest;
- accesses credentials or the network;
- changes sandbox or platform policy; or
- persists onboarding state.

Tests place a file-writing command in a valid manifest, validate it, and prove that the command was
returned unchanged but never executed and that the directory contents remained unchanged.

## M2 scope and evidence

This work is required by the active M2 completion gate. Completion evidence is the checked-in
example test, YAML/JSON equivalence, strict schema failures, budget/verification/authority policy
regressions, decoded-structure and YAML-reference limits, non-execution and non-mutation regression,
dependency audit, compilation without warnings, and full test suite.

Live onboarding, repository registration persistence, GitHub integration, command execution,
workspace creation, sandbox enforcement, and scheduler integration remain assigned to later
milestones and are explicitly out of scope.

# Connected-project manifest validation

This document is the normative loading and validation contract for the `0.1` connected-project
manifest defined by [`schemas/project.schema.json`](../schemas/project.schema.json). It implements
GitHub Issue #3 within M2. The validator itself does not onboard a repository, execute a command,
create a workspace, or persist project state. The separate M3 registry boundary described below
persists only a successful normalized result.

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

## Durable registration boundary

`Sxf.ProjectRegistry.register_repository/1` accepts manifest bytes and format together with
provider-neutral repository metadata, a platform-owned `Policy`, and actor/time/correlation
attribution. It calls `Sxf.ProjectManifest.load_string/3` before writing. A validation or policy
error therefore creates no `Project` or `RepositoryRegistration`.

One successful command atomically creates exactly one project and repository registration. The
durable repository identity is `(provider, external_id)`, where `external_id` is the provider's
stable repository identifier rather than owner/name display text. The registration stores:

- the `0.1` schema version;
- the complete normalized and policy-bounded manifest snapshot;
- SHA-256 of the exact raw manifest bytes;
- a semantic registration fingerprint; and
- the registering actor, accepted timestamp, and correlation ID.

The semantic fingerprint covers stable repository metadata, actor identity, and the normalized
manifest. Raw bytes, YAML-versus-JSON format, receive timestamp, and correlation envelope are not
semantic. Consequently, equivalent YAML and JSON replay the original registration, while changed
normalized content, owner/name, clone URL, default branch, or actor conflicts explicitly. Replay
does not replace the original raw hash or attribution.

Registration and lookup execute no manifest command, perform no network access, and create no task,
transition, inbox, outbox, attempt, lease, retry, blocker, budget, or usage record. Immediate SQLite
transactions and the unique provider/external-ID index prevent concurrent duplicate projects.
Lookup returns the persisted normalized snapshot after process or Repo restart.

Repository metadata updates, manifest-version replacement, owner/name reconciliation after rename
or transfer, and retirement/re-registration rules are deliberately deferred. A changed command may
not silently update an accepted registration.

## Manifest-gated task preparation

`Sxf.TaskPreparation` consumes only the registration's persisted normalized snapshot. It does not
reload repository bytes or trust issue text to supply commands or policy. Before a `DISCOVERED`
external-issue task can become `READY`, the gate requires inert install/test commands, effective
branch and pull-request authority, mandatory verification, and budgets within ADR 0004's M3
ceilings. It additionally rejects merge-to-default and production-deployment authority. It creates
one exact task budget, pins the registration fingerprint in the immutable preparation contract,
and stores commands in deterministic execution order.

Preparation never executes a command. Multiple processed source versions create an
`operator_input` blocker; invalid manifest authority creates a `policy` blocker. Both failures move
the task from `DISCOVERED` to `BLOCKED` without a preparation or budget. Changed registration or
source semantics conflict rather than silently replacing already prepared work. See
[`TASK_PREPARATION.md`](TASK_PREPARATION.md).

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

## M2 validation and M3 registration evidence

This work was required by the M2 completion gate. Completion evidence is the checked-in
example test, YAML/JSON equivalence, strict schema failures, budget/verification/authority policy
regressions, decoded-structure and YAML-reference limits, non-execution and non-mutation regression,
dependency audit, compilation without warnings, and full test suite.

M3 adds caller-supplied durable registration and lookup around that pure result and consumes the
normalized snapshot through the task-preparation gate. Live manifest discovery, repository
updates, command execution, workspace creation, sandbox enforcement, and live execution
integration remain explicitly out of scope.

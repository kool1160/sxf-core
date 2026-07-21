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

The manifest must explicitly declare `schemaVersion: "0.1"`. An unsupported version returns an
`unsupported_version` error at `/schemaVersion`; it is never interpreted as the nearest known
version. Unknown file extensions, malformed syntax, multiple YAML documents, duplicate properties,
unknown properties, invalid values, and missing required properties return structured
`%Sxf.ProjectManifest.Error{}` values containing a stable code, JSON Pointer path, and human-readable
message.

The schema is closed at every object boundary, including `commands`. Repository configuration
therefore cannot introduce credential, sandbox, approval-bypass, or arbitrary command fields that
the platform does not understand.

## Required declarations

The `0.1` contract requires:

- project name, description, and greenfield/existing status;
- non-empty `install` and `test` commands;
- explicit branch, pull-request, default-branch merge, and production-deployment autonomy requests;
- independent-verification and deterministic-check requirements; and
- positive cost/runtime budgets plus a bounded repair-cycle budget.

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

## Platform policy precedence

`Sxf.ProjectManifest.Policy` is platform-owned. Its default grants no autonomy and no outbound
network domains. Effective policy is computed conservatively:

- autonomy is the intersection of repository requests and platform-allowed autonomy;
- platform-required verification gates must be `true`, or validation fails with a policy conflict;
- protected paths are the union of repository and platform paths;
- prohibited actions are the union of repository, platform, and mandatory platform prohibitions;
  and
- allowed network domains are the intersection of repository and platform allowlists.

Independent verification and deterministic checks are mandatory platform verification gates.
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
    allowed_network_domains: ["github.com"]
  )

Sxf.ProjectManifest.load("project.sxf.yaml", platform_policy: policy)
```

## Safety boundary

Validation performs only bounded file metadata/read operations, parsing, schema validation, and
pure normalization. It never:

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
example test, YAML/JSON equivalence, strict schema failures, conservative policy tests, non-execution
and non-mutation regression, dependency audit, compilation without warnings, and full test suite.

Live onboarding, repository registration persistence, GitHub integration, command execution,
workspace creation, sandbox enforcement, and scheduler integration remain assigned to later
milestones and are explicitly out of scope.

# ADR 0002: Fork and harden Symphony as the Phase 1 foundation

- **Status:** Accepted (merged in [PR #9](https://github.com/kool1160/sxf-core/pull/9))
- **Date:** 2026-07-20
- **Issue:** [#1 — M1: Adopt Symphony as the SXF foundation](https://github.com/kool1160/sxf-core/issues/1)
- **Upstream evaluated:** [`openai/symphony@633eae740f807de18007f5a9a25e2e0d206afdf4`](https://github.com/openai/symphony/tree/633eae740f807de18007f5a9a25e2e0d206afdf4)

## Decision

SXF will **fork and extend the current Elixir/OTP Symphony reference implementation** for Phase 1.
It will preserve Symphony's scheduling, reconciliation, retry, workspace, workflow, and tracker
semantics, but it will not ship the reference implementation unchanged. The fork is an
upstream-tracking starting point, not a declaration that the preview is production-ready.

Phase 1 will use:

- Elixir/OTP for the control plane and scheduler;
- Ecto with SQLite in WAL mode for the first local, single-node durable store;
- a content-addressed local evidence store with metadata and hashes in SQLite;
- GitHub Issues through a GitHub App-backed adapter and webhook inbox, with polling reconciliation;
- Codex app-server as the first implementation of a vendor-neutral agent-backend behaviour; and
- Linux containers as the supported Phase 1 execution boundary, with one writable workspace per
  task attempt.

The other approaches were rejected because a new specification implementation would discard a
working orchestration kernel, while a separate Symphony service would leave Symphony's in-memory
scheduler and SXF's durable state competing to be the workflow authority.

## Context and governing constraints

SXF requires a reusable control plane, durable task and evidence history, explicit state
transitions, idempotent external actions, isolated workspaces, bounded retries and budgets,
replaceable agent runtimes, deterministic checks, and independent verification. These requirements
come from `docs/PRODUCT.md`, `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, and
`docs/RELIABILITY.md`.

The evaluated [Symphony specification](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/SPEC.md)
defines a smaller scheduler/runner: it polls a tracker, claims eligible work, creates per-issue
workspaces, runs a Codex app-server session, retries failures, and reconciles tracker state. It
explicitly treats a durable database, multi-tenant control plane, strong sandbox posture, and
built-in tracker write workflows as out of scope.

The [reference implementation README](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/README.md)
labels the code as prototype software for evaluation. The root README additionally describes it as
an engineering preview for trusted environments.

## Investigation scope and limitations

The upstream repository was cloned and pinned to commit
`633eae740f807de18007f5a9a25e2e0d206afdf4`, committed on 2026-07-20. The specification, root and
Elixir READMEs, Elixir contributor instructions, source modules, tests, workflows, `LICENSE`, and
`NOTICE` were inspected at that commit.

The implementation was compiled and smoke-run locally. Platform-neutral GitHub adapter,
orchestrator-status, and extension tests passed. The complete suite did not pass on the Windows
investigation host, and that failure is recorded below. A real GitHub/Codex end-to-end run was not
performed because upstream's test creates and mutates a disposable external issue and no scratch
repository was designated. The existence of that upstream opt-in test is not treated as proof that
it passed here.

## Findings

### Scheduler architecture

[`SymphonyElixir.Orchestrator`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/lib/symphony_elixir/orchestrator.ex)
is a GenServer and the single mutable scheduling authority. A one-for-all supervisor owns it and
the task supervisor. Each poll cycle:

1. refreshes effective configuration;
2. reconciles stalled, running, and blocked issues;
3. validates the workflow;
4. fetches active tracker candidates;
5. sorts by priority, creation time, and identifier;
6. enforces global, per-state, and per-worker limits; and
7. revalidates an issue immediately before spawning its worker.

The single-authority design and pre-dispatch revalidation are sound Phase 1 invariants. The runtime
state is nevertheless only a GenServer struct containing `running`, `claimed`, `blocked`,
`retry_attempts`, token totals, and timers.

### Workspace lifecycle and isolation

[`SymphonyElixir.Workspace`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/lib/symphony_elixir/workspace.ex)
derives a deterministic, collision-resistant workspace key from the issue identifier. Local paths
are canonicalized and checked to be below the workspace root; a workspace equal to the root or a
symlink escape is rejected. Workspaces are reused across attempts and removed after terminal-state
reconciliation. Hooks run in this order:

- `after_create` once for a new directory;
- `before_run` before every attempt;
- `after_run` after every attempt, with failures ignored; and
- `before_remove` before cleanup, with failures ignored.

This is directory isolation, not a complete security sandbox. Hooks are arbitrary trusted shell
scripts. Local hooks execute with `sh -lc` on the host. The specification recommends stronger OS,
container, VM, credential, and network boundaries but does not require one. Remote SSH execution is
an optional extension and does not perform the same canonical/symlink validation as local paths.

### Retry, recovery, and restart reconciliation

Normal worker exit schedules a one-second continuation check. Failure retries use capped
exponential backoff beginning at ten seconds. Retry refreshes release missing or ineligible issues,
delete terminal workspaces, and requeue when capacity is unavailable. Each poll detects stalled
runs and refreshes current tracker state; terminal or ineligible work stops the worker.

Restart recovery is intentionally partial:

- workspaces survive because they are filesystem directories;
- active issues are rediscovered by polling;
- terminal workspaces are cleaned during startup; but
- running sessions, blocked state, retry attempts, timers, token totals, and attempt history are
  lost.

The [specification's recovery section](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/SPEC.md#143-partial-state-recovery-restart)
states this explicitly. Tracker/filesystem recovery is useful fallback behavior, but it does not
meet SXF's durable state, audit, budget, or duplicate-side-effect requirements.

### Tracker abstraction and provider assumptions

Previous assumptions that the current implementation is Linear-only are incorrect. The pinned
commit includes Linear, GitHub Issues, Jira Cloud, Asana, GitLab, and in-memory adapters behind the
small [`SymphonyElixir.Tracker`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/lib/symphony_elixir/tracker.ex)
boundary:

- `fetch_issues_by_states/1`;
- `fetch_issues_by_ids/1`;
- optional provider-native agent tools; and
- adapter configuration validation and secret-environment declarations.

The [GitHub adapter](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/lib/symphony_elixir/github/adapter.ex)
landed in commit `044f204f161038f8a12823bbf42f85f089fc77df` on the day of this investigation.
It scopes reads to one `owner/repo`, maps issue numbers to `GH-<number>`, filters pull requests,
uses `open`/`closed` states, paginates candidate reads, and exposes a host-executed `github_api`
REST tool. Its isolated adapter tests passed locally: `8 tests, 0 failures`.

Linear assumptions still remain in defaults, compatibility fields, example workflow state names,
special-case error messages, and the repository's workflow guidance. GitHub's binary open/closed
state is also too small to represent SXF's lifecycle. SXF therefore needs internal durable task
state rather than encoding its state machine directly into provider status names.

The raw GitHub tool is not suitable unchanged for SXF. It accepts arbitrary relative GitHub REST
paths and mutating methods using the configured token. It has no SXF task-scope authorization,
idempotency key, outbox, retry classification, or platform audit boundary.

### Agent runtime abstraction and Codex assumptions

The runtime is command-configurable but not backend-neutral. [`AgentRunner`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/lib/symphony_elixir/agent_runner.ex)
calls [`Codex.AppServer`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/elixir/lib/symphony_elixir/codex/app_server.ex)
directly. The code knows Codex JSON-RPC methods, thread and turn identifiers, approval requests,
sandbox payloads, dynamic tools, token events, rate limits, and user-input signals. Orchestrator and
dashboard fields are also named for Codex.

`codex.command` can point to another executable only if that executable implements the compatible
Codex app-server protocol. This is not the replaceable agent-backend interface required by SXF.

Useful behavior should be retained: one live thread for continuation turns, bounded turns,
structured event streaming, explicit timeouts, token accounting, dynamic tool responses, and
non-stalling handling of approval or user-input requests.

### Persistence and evidence

There is no Ecto repository, database, durable queue, task ledger, attempt ledger, evidence model,
budget ledger, inbox, outbox, or append-only audit store. Ecto is used for configuration
changesets. Runtime logs rotate on local disk, while evidence is otherwise workflow-defined and
agent-reported. Neither logs nor workspaces are an authoritative task history.

Consequently, a clean agent result, terminal tracker transition, or workspace side effect cannot by
itself meet SXF's evidence and independent-verification rules.

### Security model

The implementation has meaningful baseline controls:

- canonical local workspace containment and collision-resistant names;
- Codex `workspace-write` defaults with a workspace-rooted turn policy and network disabled;
- default rejection of sandbox/rules/MCP approval requests;
- tracker tokens removed from the coding-agent child environment; and
- host-side execution of provider-native tools.

These controls are insufficient for SXF's threat model:

- arbitrary repository-owned hooks run on the host;
- provider-native tools can exercise the full authority of their configured token;
- the child can influence host-side tool arguments;
- no task-level policy decision or external mutation is durably audited;
- a local directory is not process, credential, resource, or network isolation;
- the preview explicitly targets trusted environments; and
- dependency audit findings must be remediated before any exposure of the optional HTTP server or
  tracker clients.

The CLI warning says the preview runs without the usual guardrails, while newer configuration
defaults are more restrictive. SXF must own one explicit, tested security contract rather than
depending on this documentation/configuration ambiguity.

### Licensing and attribution

Upstream is licensed under [Apache License 2.0](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/LICENSE)
and includes an OpenAI [NOTICE](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/NOTICE).
The license grants copyright and patent rights subject to its terms. A distributed fork or
derivative must, at minimum:

- include a copy of the Apache 2.0 license;
- retain applicable copyright, patent, trademark, and attribution notices;
- include the upstream NOTICE attribution in an allowed location; and
- mark modified upstream files prominently.

The license does not grant trademark rights beyond customary origin attribution, and its patent
grant contains a patent-litigation termination provision. SXF currently has no repository-root
license or NOTICE file. Importing upstream code is therefore blocked until SXF's own licensing
policy and the placement of Apache notices are decided. This ADR is technical guidance, not legal
advice; release packaging should receive license review.

## Evidence collected

### Upstream identity and change rate

```text
git rev-parse HEAD
633eae740f807de18007f5a9a25e2e0d206afdf4

git show -s --format='%cI %H %s' HEAD
2026-07-20T12:51:55-07:00 633eae740f807de18007f5a9a25e2e0d206afdf4 feat(jira): honor blocking issue links (#108)

git tag --sort=-creatordate
v0.0.1

git rev-list --count v0.0.1..HEAD
7

git diff --shortstat v0.0.1..HEAD
49 files changed, 8168 insertions(+), 913 deletions(-)
```

The repository had 36 commits at the snapshot. Its only tag was `v0.0.1`, and seven later commits
changed 49 files. This is high early-stage churn and makes a pinned, reviewed upgrade process
mandatory.

### Local build, tests, and smoke run

The host was Windows. The upstream release workflow supports Linux and macOS artifacts, and its
`make-all` CI job runs on Ubuntu. The exact declared toolchain was installed user-locally for the
investigation.

```text
elixir --version
Erlang/OTP 28 [erts-16.3] ...
Elixir 1.19.5 (compiled with Erlang/OTP 28)

mix --version
Mix 1.19.5 (compiled with Erlang/OTP 28)

mix setup
Exit 0; dependencies resolved and downloaded.

mix test
Exit 1; 291 tests, 63 failures, 6 skipped.

mix test test/symphony_elixir/github_adapter_test.exs
Exit 0; 8 tests, 0 failures.

mix test test/symphony_elixir/orchestrator_status_test.exs \
  test/symphony_elixir/extensions_test.exs
Exit 0; 56 tests, 0 failures.

mix escript.build
Exit 0; Generated escript bin/symphony with MIX_ENV=dev.
```

The full-suite failures were not hidden. They were dominated by Windows/POSIX incompatibilities:
path conversion through `sh`, CRLF-sensitive snapshots and PR-body fixtures, symlink privilege,
SSH fixture assumptions, and filesystem path expectations. Examples included malformed converted
workspace roots, failed `cp`/`git clone` hook paths, and inability to create symlinks. This supports
Linux containers as the Phase 1 runtime and means native Windows is not currently verified.

The built escript was then launched for seven seconds with the repository's in-memory tracker
fixture. Before shutdown the job state was `Running`; the status surface repeatedly showed `0/10`
agents, no retries, and a 30-second refresh countdown. It was stopped and no Erlang process
remained. This verifies local service startup and polling only. It does not verify a real tracker
mutation or Codex turn.

Upstream GitHub Actions independently reported the `make-all` workflow successful for the exact
evaluated SHA: [run 29773718641](https://github.com/openai/symphony/actions/runs/29773718641).

### Dependency audit

```text
mix hex.audit
Exit 1; Found packages with security advisories.
```

The command reported 26 advisories across the locked versions of Req, Mint, Phoenix, Bandit,
Decimal, HPAX, and Plug, including high-severity denial-of-service and request/response parsing
issues. This is snapshot evidence, not a permanent claim about later upstream revisions. Dependency
remediation and an audit gate are required before SXF imports or exposes this stack.

## Approach comparison

| Approach | Implementation speed | Reliability | Maintainability | Operating cost | Upgrade risk | Assessment |
| --- | --- | --- | --- | --- | --- | --- |
| 1. Fork and extend the Elixir reference | High | Medium initially | Medium | Low for Phase 1 | Medium-high | Reuses tested scheduler/OTP behavior and current GitHub work, but requires disciplined seams and a small patch surface. Selected. |
| 2. Implement the specification in another stack | Low | Low initially | Potentially high later | Medium | Medium | Avoids Elixir and fork divergence, but recreates concurrency, retry, protocol, and conformance behavior before delivering SXF durability or evidence. |
| 3. Run Symphony as a separate service | Medium | Low for SXF invariants | Low-medium | Highest | Medium | The available API is an observability surface, not a durable command contract. A second durable SXF controller would create split ownership of claims, retries, cancellation, and restart recovery. |

Approach 1 has the lowest total Phase 1 risk if the fork is kept narrow. Approach 2 optimizes for
technology preference rather than verified delivery. Approach 3 appears operationally clean but
puts the required durable state outside Symphony while leaving dispatch authority inside it, which
is precisely the split-brain architecture SXF should avoid.

## What SXF will reuse unchanged

“Unchanged” here means preserving semantics and upstream conformance tests; persistence plumbing
may move code without changing the decision rules.

- Single-authority scheduling and serialized claim mutation.
- Candidate normalization, stable IDs, state normalization, required-label filtering, dispatch
  sorting, and immediate pre-dispatch revalidation.
- Global and per-state concurrency semantics.
- One-second continuation checks and capped exponential failure backoff.
- Reconciliation rules for active, unroutable, missing, stalled, non-active, and terminal issues.
- Collision-resistant workspace keys, local root containment, workspace reuse, and lifecycle-hook
  ordering.
- Strict repository-owned prompt rendering and last-known-good dynamic workflow reload.
- Structured agent events, bounded turns, timeouts, and absolute-token delta accounting.
- The small tracker read contract and provider-specific normalization boundary.
- Upstream core-conformance tests as a required baseline suite.

## What SXF will wrap behind interfaces

- **TaskStore** — transactional task, attempt, transition, retry, lease, budget, inbox, and outbox
  persistence.
- **TrackerAdapter** — candidate/state reads and normalized issue data. Provider mutation is not
  part of the scheduler contract.
- **GitHubGateway** — GitHub App authentication, scoped reads/writes, webhook verification,
  idempotency, rate limits, and mutation audit.
- **AgentBackend** — start, resume, cancel, inspect, stream events, report usage, and declare
  capabilities.
- **WorkspaceBackend** — prepare, validate, inspect, archive, and remove a workspace.
- **SandboxBackend** — launch and terminate isolated execution with explicit filesystem, process,
  credential, resource, and network policy.
- **EvidenceStore** — append/finalize immutable artifacts and retrieve them by content hash.
- **Clock/Timer** — persist `due_at` values and make retry/restart behavior deterministically
  testable rather than treating process timer references as state.

## What SXF must replace or extend

- Replace the in-memory-only state struct as the authority with durable task/attempt projections
  and an append-only transition ledger.
- Persist retries, blocked states, leases, budgets, agent session identities, usage, and outcomes.
- Replace raw provider-native mutation tools with policy-checked, task-scoped capabilities.
- Extend the single-repository tracker scope with stable project and repository IDs.
- Map the full SXF lifecycle internally instead of overloading GitHub open/closed state.
- Replace host-executed trusted hooks with sandbox-executed repository commands under policy.
- Decouple scheduler, events, telemetry, and status models from Codex-specific names and methods.
- Add deterministic gates, durable evidence, verification verdicts, repair budgets, and human
  escalation packages.
- Add webhook inbox/outbox idempotency and periodic reconciliation for missed or duplicated events.
- Remediate locked dependency advisories and make dependency audit a release gate.

## GitHub Issues integration strategy

1. Use a GitHub App installed only on selected repositories. Workers receive short-lived,
   repository-scoped tokens only when needed.
2. Verify webhook signatures, store delivery IDs in a durable inbox, and process each delivery
   idempotently. Polling remains a reconciliation fallback.
3. Normalize a GitHub issue into an SXF task using `(project_id, repository_id, issue_number)` as
   durable identity. Do not use `GH-<number>` alone across repositories.
4. Keep GitHub issue state as intake/handoff metadata. SXF's durable state machine is authoritative.
   Labels, comments, check runs, or project fields may mirror status but cannot define correctness.
5. Route every comment, label, branch, status, and pull-request mutation through a transactional
   outbox with a stable idempotency key and recorded response.
6. Expose narrow capabilities to agents, such as `read_issue`, `add_task_comment`, or
   `attach_pull_request`, rather than an unrestricted relative REST path.
7. Reconcile external issue, branch, PR, and CI state after restart and before any repeated write.

The upstream GitHub normalization and tests are useful starting material. Its static token and raw
`github_api` mutation surface must not become the permanent SXF security boundary.

## Durable task-state strategy

SQLite in WAL mode is the Phase 1 source of truth because the first release is a local,
single-control-plane vertical slice with one workspace at a time. It provides transactions, crash
recovery, backups, and low operating cost without adding a distributed service. Ecto migrations and
repository behaviours must avoid SQLite-specific domain semantics so PostgreSQL can replace it
when multi-node scheduling is justified.

Minimum durable records:

- projects and repository registrations;
- normalized tasks and current-state projections;
- task attempts and backend session identities;
- append-only task transition events with actor and correlation IDs;
- retry schedules with wall-clock `due_at`, reason, and attempt number;
- task/attempt budgets and usage entries;
- worker leases and heartbeats;
- webhook inbox deliveries and external-action outbox entries;
- evidence metadata, hashes, and finalization state; and
- audit records for policy decisions and external mutations.

Each transition transaction appends an event, updates the task/attempt projection, adjusts budgets
or leases, and inserts any required outbox action. A worker may act only while holding a valid
attempt lease. All state-changing handlers accept stable idempotency keys.

On restart the control plane will:

1. load non-terminal tasks, due retries, leases, and unsent outbox actions;
2. expire stale leases and classify orphaned attempts;
3. inspect preserved workspaces and backend sessions without assuming either is healthy;
4. reconcile GitHub issue, branch, PR, and CI state;
5. resume only when the backend explicitly supports safe resume;
6. otherwise create a new bounded attempt with the prior evidence summary; and
7. never convert unknown state to success.

## Durable evidence storage strategy

Phase 1 evidence bytes will be written to a configurable local content-addressed store. SQLite will
hold task/attempt association, media type, command, timestamps, exit status, byte length, SHA-256,
redaction status, producer identity, and finalization metadata.

Evidence includes exact commands, stdout/stderr or bounded log artifacts, check results, commit and
diff identity, agent event summaries, usage, security findings, and acceptance verdicts. Writes use
temporary files followed by atomic rename. Finalized evidence is immutable; later annotations are
new records. Secrets are redacted before finalization, and raw secret-bearing output is not retained
by default.

`EvidenceStore` will allow later replacement with object storage without changing scheduler or
verification semantics. A workspace and rotating application log are never evidence by themselves.

## Workspace and sandbox strategy

Phase 1 is supported on Linux containers, including development on non-Linux hosts through a Linux
container runtime. Native Windows execution is deferred because the current upstream suite failed
material path, shell, line-ending, and symlink assumptions on the investigation host.

Each attempt receives:

- a dedicated workspace directory below an SXF-owned root;
- an isolated clone populated from a read-only repository cache, not a shared writable checkout;
- a unique branch and attempt identity;
- only task-scoped credentials and environment variables;
- CPU, memory, process, disk, and wall-clock limits;
- a default-deny network policy with project-declared allowlists; and
- Codex's workspace policy as defense in depth, not the outer sandbox.

Repository hooks and manifest commands execute inside the worker sandbox, never in the control-plane
process. Workers do not share writable filesystems, credentials, process namespaces, or unscoped
caches. Workspace removal validates canonical containment again and records cleanup evidence.
`SandboxBackend` may later use stronger containers, microVMs, or remote workers without changing the
task state machine.

## Agent backend abstraction strategy

The neutral behaviour must support:

- `start(attempt, workspace, prompt, policy)`;
- `resume(session_id, context)` when supported;
- `cancel(session_id, reason)`;
- `inspect(session_id)`;
- structured event streaming;
- usage and cost reporting;
- capability and protocol-version reporting; and
- explicit completion, failure, blocked, and unknown outcomes.

Codex app-server becomes `AgentBackend.Codex`. It owns Codex method names, approval/sandbox payloads,
thread/turn handling, dynamic tools, and token/rate-limit translation. Core orchestration consumes
neutral events and never branches on Codex protocol strings. Backend conformance tests will be
shared by every implementation. A second backend is deferred until Phase 4, but the boundary is a
Phase 1 requirement so persistence does not encode Codex-specific session semantics.

## Testing and verification strategy

- Preserve and run upstream core-conformance tests on every upstream merge.
- Run format, specs, lint, coverage, dialyzer, dependency audit, and license/NOTICE checks in Linux
  CI.
- Add contract suites for tracker, GitHub gateway, agent backend, workspace, sandbox, task store,
  and evidence store.
- Use deterministic fake clock, tracker, backend, and external-action adapters for scheduler tests.
- Crash after every state-transition/outbox boundary to prove restart reconciliation and
  idempotency.
- Test duplicate/out-of-order webhooks, stale leases, lost heartbeats, retry exhaustion, budget
  exhaustion, malformed provider payloads, and partially completed external mutations.
- Test path traversal, symlink escape, secret redaction, prompt injection boundaries, network
  denial, and cross-project leakage.
- Run opt-in real GitHub/Codex end-to-end tests only in a designated disposable repository, record
  their external resource IDs, and clean them idempotently.
- Treat deterministic failures as authoritative. No agent review can override a failed check.
- Phase 1 records deterministic evidence and explicit acceptance verdicts. Independent verifier
  execution remains the Phase 2 milestone, and the schema/interface must support it without
  retrofitting task history.

## Upgrade strategy

1. Record the exact upstream commit in source metadata and release notes.
2. Maintain a pristine upstream-tracking branch or vendored subtree plus a small, reviewable SXF
   patch series. Do not copy source without history and provenance.
3. Put SXF persistence, policy, GitHub, sandbox, evidence, and backend behavior behind explicit
   boundaries so upstream scheduler changes can be compared semantically.
4. Import upstream changes only through dedicated upgrade pull requests.
5. For each upgrade, inspect the spec diff, implementation diff, migrations, dependency audit,
   license/NOTICE changes, protocol compatibility, and security posture.
6. Run upstream conformance, SXF contract, restart/fault-injection, and designated real-integration
   profiles before promotion.
7. Never auto-merge upstream `main`. Prefer tagged releases after maturity; until then pin commits
   and review on a regular cadence.
8. Upstream useful fixes should be contributed back when they do not contain SXF-specific policy or
   persistence assumptions.

## Consequences and technical risks

### Positive

- SXF starts from verified scheduler, retry, reconciliation, workspace, tracker, and Codex protocol
  behavior rather than recreating it.
- Elixir/OTP matches the long-running, failure-supervised control-plane problem.
- The newly added GitHub adapter materially reduces Phase 1 tracker work.
- One control plane remains authoritative; no cross-service scheduler split is introduced.
- SQLite and local content-addressed evidence keep the first deployment inexpensive and operable.

### Negative and migration risks

- The upstream project is a rapidly changing `v0.0.1` preview; the fork can diverge quickly.
- Adding durability to an in-memory scheduler touches its central concurrency boundary and can
  introduce duplicate or lost work if transactions and leases are wrong.
- SQLite will require a planned migration to PostgreSQL before multi-node writers or higher write
  concurrency; migration tooling and stable domain IDs are required from the start.
- Codex protocol changes can break the first backend even when scheduler behavior is unchanged.
- Current GitHub support is new, uses only open/closed states, and has not been live-tested in this
  investigation.
- The raw provider tool and trusted hook model are unsafe if accidentally retained.
- Existing locked dependencies have current advisories and must be upgraded without weakening the
  test baseline.
- Linux containers become a Phase 1 platform requirement; native Windows support is deferred.
- SXF has no current top-level license/NOTICE, so upstream source import cannot begin until the
  licensing decision is made.
- Content-addressed local evidence needs backup and corruption-recovery procedures before it can be
  considered durable beyond one host.

## Deferred decisions

- PostgreSQL migration timing and multi-node queue/lease design.
- Production object storage and retention policy for evidence.
- Stronger sandbox technology beyond the Phase 1 Linux container boundary.
- Remote worker placement and SSH-worker compatibility.
- Second agent backend and cross-backend verifier selection.
- Full independent verification and bounded repair orchestration, scheduled for Phase 2.
- GitHub Projects field mapping and richer operator-facing status mirroring.
- Dashboard and observability vendor choices.
- Native Windows execution support.
- Public SXF licensing terms, subject to preserving Apache 2.0 obligations for imported code.

## Remaining open questions

1. Which disposable GitHub repository will be used for the real GitHub/Codex end-to-end gate?
2. Will SXF be distributed under Apache 2.0 or another compatible top-level license, and where will
   upstream NOTICE/change markers be surfaced?
3. Which container runtime is the supported Phase 1 default, and how will default-deny networking
   be enforced consistently in local development and CI?
4. What backup/restore objective is required for the Phase 1 SQLite database and local evidence
   store?
5. Which upstream dependency versions clear the recorded advisories while preserving the passing
   Linux conformance suite?

These questions affect implementation and release readiness, but they do not prevent selecting the
fork-and-harden approach.

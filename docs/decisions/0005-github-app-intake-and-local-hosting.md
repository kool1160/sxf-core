# ADR 0005: Use local polling for bounded M3 GitHub issue intake

- **Status:** Accepted
- **Date:** 2026-07-27
- **Issue:** [#23 — M3: define GitHub App intake and local hosting boundary](https://github.com/kool1160/sxf-core/issues/23)
- **Parent milestone issue:** [#4 — M3: Build the first single-repository execution vertical slice](https://github.com/kool1160/sxf-core/issues/4)

## Context

M3 must ingest one ready GitHub issue without manual copying while preserving SQLite as SXF's sole
workflow authority. ADR 0002 anticipated a GitHub App adapter with webhook intake and polling
reconciliation. ADR 0004 then restricted the M3 App installation and permissions to the public,
synthetic `kool1160/sxf-m3-scratch` repository. The remaining hosting decision is whether the local
M3 control plane must expose a public webhook endpoint or can use a smaller intake boundary.

Public webhook hosting would add inbound networking, TLS, delivery verification, replay protection,
and service availability to the first execution slice. Those concerns are valuable later, but they
are not needed to prove the M3 issue-to-pull-request loop. Polling can satisfy M3 only if it uses the
same durable inbox, identity, policy, and idempotency boundaries required of a future webhook
adapter.

## Decision

### Local control plane and polling

The M3 SXF control plane runs locally in the operator-controlled environment. It does not expose a
public inbound webhook endpoint. A control-plane intake adapter polls GitHub for issues in
`kool1160/sxf-m3-scratch` that carry the exact `sxf:ready` label.

The GitHub App is installed only on `kool1160/sxf-m3-scratch`, with the permissions accepted in ADR
0004. Polling is performed with installation identity, not a personal access token. Label presence
is an intake eligibility observation; it does not authorize a state transition, expand policy, or
replace the durable SXF lifecycle.

Polling cadence, backoff intervals, and operator startup packaging remain implementation details.
They must be bounded and testable, but this decision does not implement them.

### Credential custody

The GitHub App private key and the ability to mint installation access tokens remain exclusively in
the control plane. The private key must never enter a worker, workspace, prompt, model context, log,
evidence artifact, or connected repository.

When a later M3 execution step requires GitHub access, the control plane may provide a worker only a
short-lived installation token scoped to `kool1160/sxf-m3-scratch` and reduced to the permissions
needed for that task. A worker never receives the App private key, a broad personal credential, or
authority for another repository. Token values are not durable task data and must be redacted from
events and evidence.

### Stable source identity

GitHub names and issue numbers are useful display values but are not the durable cross-rename
identity. Intake uses:

- the GitHub repository database ID as the provider-stable repository identity; and
- the GitHub issue database ID as the provider-stable source-item identity.

The repository registration retains the current owner/name and issue metadata for display and
reconciliation. A normalized task carries the stable repository registration and opaque GitHub
issue identity as its source reference. Repository rename or transfer must reconcile the display
metadata without creating a new repository registration or task. An issue number is never treated
as globally unique.

### Durable inbox and idempotent normalization

Every accepted poll observation is persisted through the external-event inbox before task
normalization. The adapter derives a deterministic observation identity from the provider,
repository ID, issue ID, and GitHub source version such as `updated_at`, and stores a payload hash.

Inbox acceptance and normalized task creation or reconciliation occur in one durable command
boundary:

1. Re-observing the same source version and payload returns the prior inbox result.
2. Reusing an observation identity with different accepted content is an idempotency conflict.
3. A later source version creates a new inbox observation but reconciles the same task source
   identity.
4. Concurrent or repeated polling cannot create more than one durable task for the same repository
   and GitHub issue IDs.

The inbox record is an external fact, not task truth. SXF's task ledger, transitions, claims,
attempts, leases, budgets, blockers, and terminal outcomes remain authoritative. Neither the poller
nor GitHub issue state may dispatch work directly.

### Untrusted content and authority

Issue titles, bodies, comments, labels other than the configured readiness label, and linked content
are untrusted input. They may describe requested work but cannot:

- change the App installation or permission set;
- select another repository;
- raise autonomy, network, runtime, turn, retry, repair, or cost ceilings;
- override the connected-project manifest or platform policy;
- disclose or request credentials; or
- authorize protected or destructive actions.

The connected-project manifest is loaded and validated through the existing bounded manifest
boundary before a normalized task becomes executable. Issue text is data supplied to later planning
and execution only after platform authority has already been fixed.

### Safe failure behavior

Intake stops without creating executable or duplicate work when:

- GitHub rate limits are exhausted or a secondary limit is reported;
- App authentication or installation-token minting fails;
- the configured installation or repository is unavailable, removed, renamed without successful
  reconciliation, or outside the accepted installation scope; or
- the connected repository manifest is absent, malformed, unsupported, or violates platform
  policy.

Rate-limit responses must honor GitHub-provided reset or retry information and must not hot-loop.
Authentication and repository-scope failures require operator-visible blocking evidence rather than
credential fallback. Manifest failures retain their structured validation errors. Unknown external
state never becomes task success or implied authorization.

### Replaceable webhook adapter

A later milestone may add signed webhook delivery intake. That adapter must write through the same
durable inbox and task-normalization boundary, use stable repository and issue identities, and
coexist with polling reconciliation idempotently. It may improve latency but cannot dispatch work
directly or become a second workflow authority.

Public webhook hosting, signature validation infrastructure, delivery operations, and availability
engineering remain deferred. Adding them requires a bounded design and security review; it does not
replace this decision's authority and idempotency rules.

## Consequences

### Positive

- M3 avoids public ingress, TLS termination, and webhook availability dependencies.
- The single-repository App installation and local control plane minimize credential and blast
  radius.
- Stable provider IDs and the durable inbox make polling replay and later webhook reconciliation
  deterministic.
- The same task ledger remains authoritative regardless of intake transport.

### Negative

- Intake latency is bounded by the polling interval.
- Polling consumes GitHub API quota and must suspend safely on rate limits.
- The operator must run the local control plane and provide the App credential through an approved
  secret boundary.
- A later webhook adapter still requires separate hosting and signature-verification work.

## Rejected alternatives

**Public webhooks during M3** were rejected because they add public hosting and inbound security
work that is not required for the first vertical slice.

**Personal access tokens** were rejected because they provide broader, longer-lived user authority
than the repository-scoped GitHub App installation.

**Letting workers poll or mint tokens** was rejected because it would expose control-plane
credentials and allow workers to acquire authority outside a durable task grant.

**Treating GitHub labels or issue state as workflow truth** was rejected because it would create a
second state machine outside the SXF ledger.

## Scope

This ADR changes documentation only. It does not implement GitHub API calls, App authentication,
private-key storage, token minting, polling, webhook handling, repository mutation, workers,
containers, Codex execution, M4 verification, repair, or automatic merge.

# Bounded GitHub App issue intake

This document defines the implemented M3 provider adapter selected by
[ADR 0005](decisions/0005-github-app-intake-and-local-hosting.md). It covers one explicit
`Sxf.GitHub.IssuePoller.poll_once/1` call. It does not authorize a permanent polling loop, live
credentials in tests or CI, repository mutation, task dispatch, or worker execution.

## Boundaries

The adapter is split into independently testable control-plane boundaries:

- `Sxf.GitHub.AppAuth` signs a GitHub App JWT and exchanges it for one installation token.
- `Sxf.GitHub.Transport` owns the HTTP request/response boundary; focused tests inject a function,
  while `Sxf.GitHub.HttpcTransport` is the explicit OTP production implementation.
- `Sxf.GitHub.Client` sends the minimal REST reads and converts provider status, request, and
  rate-limit headers into secret-free results.
- `Sxf.GitHub.IssuePoller` resolves durable repository authority, fetches one complete bounded
  provider view, canonicalizes observations, and calls `Sxf.Tasks.normalize_external_issue/1`.

The clock, HTTP transport, private-key resolver, and correlation-ID generator are injected. Focused
tests require no environment variables, wall clock, or network.

## Authentication and secret custody

App authentication uses RS256 with an RSA private key decoded from an approved PEM representation.
`iat` is the trusted current time minus 60 seconds. `exp` is exactly 600 seconds after `iat`, and
`iss` is the configured App ID. Malformed, encrypted, public-only, or unsupported key material
returns a stable error without including key bytes.

The JWT is exchanged at:

```text
POST /app/installations/{installation_id}/access_tokens
```

The request contains only the registered GitHub repository database ID and these material
permissions:

| Permission | Requested access |
| --- | --- |
| Contents | Write |
| Issues | Read |
| Pull requests | Write |
| Metadata | Implicit read |

An all-repository token, another exposed repository, another exposed installation, missing required
permission, or broader material permission is rejected. The token is opaque: no length, prefix, or
format is assumed. There is no personal-token fallback.

Private-key data, JWTs, installation tokens, and authorization headers remain in the local control
plane. The in-memory installation-token value has a redacting `Inspect` implementation. These
values are never returned in the poll summary, placed in errors or logs, persisted in SQLite, or
supplied to issue content, task metadata, workers, prompts, backends, or evidence.

## Repository authority

The caller supplies the stable GitHub repository database ID. The poller looks it up through
`Sxf.ProjectRegistry` under provider `github` and requires:

- one complete active registration;
- owner `kool1160`;
- repository name `sxf-m3-scratch`; and
- the normalized, policy-bounded manifest accepted during registration.

Before issue reads, `GET /repositories/{repository_id}` must return the same database ID, owner, and
name and must not report an archived repository. Missing or incomplete registration, another
provider, another repository, an unavailable or archived repository, and owner/name mismatch fail
closed. Rename and transfer reconciliation remains deferred; this adapter never silently updates
durable registration metadata.

## One-shot provider view

One poll:

1. mints one repository-scoped installation token;
2. verifies the repository identity;
3. requests open issues with the exact `sxf:ready` label, `updated` sort, ascending direction,
   explicit page number, and at most 100 records per page;
4. follows explicit provider `next` links within caller-configured page and observation ceilings;
5. fetches the complete bounded view before any durable normalization;
6. excludes pull requests from the shared Issues endpoint;
7. independently enforces open state and exact case-sensitive label presence;
8. isolates malformed individual issues only after the repository view is authoritative; and
9. orders accepted observations by parsed `updated_at` with a stable issue-ID tiebreaker.

The adapter has no sleep, recurring timer, background process, hot loop, or automatic retry. A
later-page error or a page/observation overflow creates no tasks from earlier pages.

## Canonical observation and replay

Accepted observations use:

- the GitHub repository database ID as `repository_external_id`;
- the GitHub issue database ID as `issue_external_id`;
- `updated_at` as `source_version`;
- bounded issue title and body;
- issue number, repository display name, URLs, sorted label display data, state, and author display
  data as untrusted metadata;
- the configured external-system actor; and
- a fresh injected control-plane correlation ID.

`payload_sha256` is computed from a deterministic encoding of those semantic fields. Raw JSON
bytes, map property order, whitespace, HTTP headers, page envelopes, provider request IDs, receive
times, and unrelated provider fields do not participate. Label display entries are sorted before
hashing.

Every accepted observation passes through `Sxf.Tasks.normalize_external_issue/1`. The first creates
one processed inbox row, one `DISCOVERED` task, and one creation transition. Exact replay returns
the same result. A later `updated_at` creates another inbox observation linked to the same task.
Reusing one source version with changed canonical content is counted as an idempotency conflict.
Polling never promotes a task or creates attempts, leases, retries, blockers, budgets, usage, an
outbox action, workspace, or dispatch.

## Results and failures

A successful poll returns only a secret-free summary: repository identity, pages fetched,
observations seen, accepted issues, tasks created, observation replays, normalization conflicts,
malformed-observation classifications, safe provider request IDs, current rate-limit metadata, and
an optional retry timestamp.

JWT, installation-token, authentication, permission, installation, repository identity,
repository availability, malformed repository/page, page-limit, and observation-limit failures
stop the poll. HTTP 401, 403, 404, 422, 429, and 5xx responses receive explicit stable
classifications. Primary and secondary rate limits honor `Retry-After` first and otherwise use the
provider reset timestamp. The adapter returns that instruction and never sleeps.

## Verification and live setup

Focused tests verify the RS256 signature and claims, PEM failures, exact token scope and permission
request, response-scope rejection, redaction, repository checks, exact filtering, multiple pages,
ordering, bounds, canonical identity, durable replay/conflict behavior, provider failures, zero
execution records, and absence of secrets from durable rows. A separate temporary SQLite process
stops and restarts the Repo before an exact repeated poll and proves no duplicate work. Every test
uses an injected transport; no root-suite test contacts GitHub.

The public synthetic `kool1160/sxf-m3-scratch` repository, App creation, App installation, and
approved private-key provisioning remain operator-controlled external setup. This implementation
is not evidence of live M3 ingestion. A live smoke test requires separate explicit authorization,
credential-safe operation, and recorded provider evidence.

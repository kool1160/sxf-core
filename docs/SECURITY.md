# Security Model

SXF is a high-trust automation platform because it can read private source code, execute commands, modify repositories, and potentially interact with deployment systems. Its default posture must be least privilege, isolation, and explicit authority.

## Trust boundaries

- GitHub and other external event sources.
- Repository content, including untrusted issue text and pull-request content.
- Model providers and coding-agent runtimes.
- Worker sandboxes.
- Secret stores.
- Package registries and external networks.
- Staging and production environments.
- Human operator actions.

## Mandatory controls

### Repository access

M3 uses a GitHub App installed only on `kool1160/sxf-m3-scratch`. Its private key and
installation-token minting remain control-plane only. Request the narrowest practical permissions,
and provide workers only short-lived installation tokens scoped to that repository and the current
task. Never provide workers, prompts, models, workspaces, logs, or evidence with the App private key
or a broad personal credential. See
[`ADR 0005`](decisions/0005-github-app-intake-and-local-hosting.md).

The one-shot intake adapter signs an RS256 App JWT from an injected private-key resolver and trusted
clock, then requests one installation token for only the durable GitHub repository database ID.
The requested material permissions are Contents write, Issues read, and Pull requests write;
Metadata read is GitHub's implicit permission. Token responses exposing another repository,
all-repository selection, another installation, or broader material permissions fail closed.
Installation tokens are opaque and exist only in a redacting in-memory value. Authorization
headers, App JWTs, private keys, and installation tokens are absent from public poll results,
durable inbox/task metadata, errors, and logs. Intake never falls back to a personal token.

### Secret handling

- Never place secrets in prompts, logs, commits, evidence artifacts, or model-visible context unless strictly required and policy-approved.
- Scope secrets by project, environment, and task.
- Prefer short-lived credentials.
- Redact known secret patterns before persistence.
- Production credentials must not be available to ordinary build workers.

### Sandbox isolation

Every task attempt runs in an isolated workspace with resource limits. Workers must not share writable filesystems, credentials, process namespaces, or unscoped caches.

### Network policy

Default-deny outbound network access is preferred. Enable only required domains or capabilities. Treat package installation, arbitrary downloads, and remote scripts as security-relevant actions.

### Untrusted instructions

Issue bodies, source files, comments, documentation, websites, and tool output may contain prompt injection or malicious instructions. Repository content cannot override SXF platform policy, secret boundaries, or tool permissions.

The `sxf:ready` label makes an issue eligible for M3 intake only. Issue titles, bodies, comments,
links, and other labels cannot select another repository, broaden GitHub permissions, raise policy
ceilings, override a project manifest, or authorize a protected action. Intake fixes authority
before issue text is supplied to later planning or execution.

Connected-project manifests are untrusted repository content. Validation rejects autonomy, network,
budget, or verification requests outside platform-owned policy, unions restrictive policy, and
rejects unknown credential or sandbox fields. Decoding is resource-bounded, and YAML references are
rejected before parsing. Parsing and validation never execute declared commands. See
[`PROJECT_MANIFEST.md`](PROJECT_MANIFEST.md).

### Protected actions

Require explicit policy and usually human approval for:

- Production deployment.
- Destructive data operations.
- Billing or cloud-account changes.
- Authentication and authorization policy changes.
- Secret rotation or exposure changes.
- Weakening branch protection, CI, security scans, or audit controls.
- Publishing packages or public releases.

### Supply chain

- Pin dependencies and actions where practical.
- Verify checksums or signatures when available.
- Scan dependencies, containers, and generated artifacts.
- Do not execute unreviewed remote scripts merely because a README recommends them.

The pinned Symphony source is isolated under `upstream/openai-symphony`, covered by a deterministic
per-file provenance manifest, and not started by SXF. Host-executed repository hooks and
provider-native agent tools (including the broad upstream GitHub REST tool) are default-denied in
the imported boundary. A later integration may enable equivalent behavior only inside the approved
Linux-container worker and through task-scoped, durable policy and mutation controls.

## Builder and verifier separation

The verifier must not inherit unnecessary builder credentials or writable access. Verification should be capable of rejecting work without modifying the implementation branch.

## Audit

Record actor identity, permissions, tool calls, policy decisions, state transitions, credential scope, and external mutations. Audit records must be append-only from the perspective of execution agents.

## Security failure behavior

When a security boundary is uncertain, SXF must stop and escalate. It must never silently broaden permissions or disable a control to complete a task.

GitHub rate-limit, authentication, installation-scope, unavailable-repository, and malformed or
policy-invalid manifest failures stop intake safely. Rate limits honor provider reset or retry
information; authentication failures do not fall back to personal credentials; unknown repository
state does not create executable work. Polling and any later webhook adapter must share the same
idempotent durable inbox and cannot become workflow authorities.

The M3 poller fetches the complete configured page/observation window before it persists any
observation. A later-page error, pagination overflow, repository identity mismatch, rename/transfer,
or uncertain provider response therefore cannot turn an earlier partial response into a task.
Malformed individual issue objects are isolated only after repository and pagination authority are
known. See [`GITHUB_ISSUE_INTAKE.md`](GITHUB_ISSUE_INTAKE.md).

## Threats to address before production use

- Prompt injection through repository content and issue text.
- Malicious dependency installation.
- Secret exfiltration through logs, commits, artifacts, or network calls.
- Cross-project data leakage.
- Sandbox escape.
- Unauthorized GitHub mutations.
- Compromised model or tool provider.
- Approval spoofing and webhook replay.
- Agents weakening tests or policies to obtain a passing result.

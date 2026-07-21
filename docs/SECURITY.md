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

Use a GitHub App installed only on selected repositories. Request the narrowest practical permissions and issue short-lived installation tokens to workers.

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

Connected-project manifests are untrusted repository content. Validation treats autonomy fields as
requests, intersects them with a default-deny platform ceiling, unions restrictive policy, and
rejects unknown credential or sandbox fields. Parsing and validation never execute declared
commands. See [`PROJECT_MANIFEST.md`](PROJECT_MANIFEST.md).

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

## Builder and verifier separation

The verifier must not inherit unnecessary builder credentials or writable access. Verification should be capable of rejecting work without modifying the implementation branch.

## Audit

Record actor identity, permissions, tool calls, policy decisions, state transitions, credential scope, and external mutations. Audit records must be append-only from the perspective of execution agents.

## Security failure behavior

When a security boundary is uncertain, SXF must stop and escalate. It must never silently broaden permissions or disable a control to complete a task.

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

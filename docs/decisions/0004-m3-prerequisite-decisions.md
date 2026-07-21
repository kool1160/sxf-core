# ADR 0004: Record M3 licensing, execution boundary, and controlled demonstration prerequisites

- **Status:** Accepted
- **Date:** 2026-07-21
- **Issue:** [#15 — M3 prerequisite: lock licensing, runtime, scratch repository, and demo budgets](https://github.com/kool1160/sxf-core/issues/15)
- **Parent milestone issue:** [#4 — M3: Build the first single-repository execution vertical slice](https://github.com/kool1160/sxf-core/issues/4)

## Context

ADR 0002 selected an upstream-tracked Symphony fork, Linux containers, a GitHub App boundary, and
a controlled real GitHub/Codex demonstration. Before any upstream import or M3 execution work,
SXF needs a durable license boundary, an exact provenance record, one supported local runtime path,
one disposable repository, narrow GitHub authority, and fixed demonstration limits.

## Decision

### SXF and third-party licensing

Original SXF code is proprietary and all rights are reserved. The root [`LICENSE`](../../LICENSE)
applies only to original SXF code. It does not relicense third-party material.

Imported Symphony source and any modifications to that source remain subject to Apache License 2.0.
Before an import, the importing change must preserve upstream copyright, patent, trademark, and
attribution notices; include the Apache license and the applicable NOTICE text; record pinned
provenance; and mark modified upstream files prominently. Formal commercial distribution of SXF
requires legal review.

The exact prerequisite licensing material for the pinned upstream is retained separately:

| Material | Repository location | Pinned upstream source | SHA-256 of inspected upstream file |
| --- | --- | --- | --- |
| Apache License 2.0 | [`licenses/Apache-2.0.txt`](../../licenses/Apache-2.0.txt) | [`openai/symphony@633eae740f807de18007f5a9a25e2e0d206afdf4/LICENSE`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/LICENSE) | `1EB85FC97224598DAD1852B5D6483BBCF0AA8608790DCC657A5A2A761AE9C8C6` |
| OpenAI Symphony NOTICE | [`licenses/symphony-NOTICE.txt`](../../licenses/symphony-NOTICE.txt) | [`openai/symphony@633eae740f807de18007f5a9a25e2e0d206afdf4/NOTICE`](https://github.com/openai/symphony/blob/633eae740f807de18007f5a9a25e2e0d206afdf4/NOTICE) | `3548E073B06BA499E9423158A663FBF4506AB9722DE33FE9550BA62D69808FB5` |

No Symphony source is imported by this decision. The copied license and NOTICE text are retained
solely to establish the required attribution and provenance structure before a later dedicated
source-import pull request.

Every later imported Symphony file must retain its upstream notices and include a prominent,
language-appropriate modification notice naming SXF, the pinned upstream repository, commit, and
original path. The associated pull request must list the imported paths, upstream commit, exact
source provenance, and a concise change summary. A generic repository-level notice alone is not a
substitute for modified-file marking.

### Supported execution boundary

Docker Desktop with the WSL2 backend is the supported Windows development route. Linux containers
are the authoritative M3 worker boundary. Native Windows worker execution is unsupported.

Docker installation and configuration remain operator-controlled. The later M3 implementation must
run repository commands and agent execution inside the Linux worker boundary, not in the Windows
control-plane process.

### Controlled M3 demonstration repository

The designated M3 live demonstration target is
[`kool1160/sxf-m3-scratch`](https://github.com/kool1160/sxf-m3-scratch). Once operator setup is
complete, it must be public and synthetic, and used only for controlled issue-to-pull-request
demonstrations. FXD, BDFA, Applied Intelligence, and other valuable repositories are prohibited
as M3 test targets.

The repository's creation, availability, manifest, issues, and cleanup are external
operator-controlled setup. This ADR does not create, mutate, or claim to verify that repository.

### GitHub authority

The GitHub App must be installed only on `kool1160/sxf-m3-scratch` for the M3 demonstration. Its
approved permissions are:

| Permission | Access |
| --- | --- |
| Metadata | Read |
| Contents | Read and write |
| Issues | Read |
| Pull requests | Read and write |

Workers may receive only short-lived, repository-scoped installation credentials needed for the
specific task. Broad personal credentials must never be passed to workers, prompts, containers,
logs, evidence, or agent backends.

GitHub App creation and installation are operator-controlled external setup. This ADR does not
create or configure an App, mint credentials, or mutate GitHub.

### M3 demonstration limits

The M3 demonstration uses these hard limits:

| Limit | Approved value | Durable representation |
| --- | ---: | ---: |
| Cost | $2.00 | 2,000,000 microusd |
| Runtime | 15 minutes | 900,000 ms |
| Agent turns | 20 | 20 turns |
| Provider retries | 2 | 2 retries |
| Repair cycles | 0 | 0 cycles |

Reaching any applicable limit must follow the durable budget/blocking semantics in
[`TASK_DOMAIN.md`](../TASK_DOMAIN.md). The zero repair-cycle limit does not authorize M4 repair
behavior.

## Consequences

- Symphony import work may proceed only in a separate, reviewable source-import pull request that
  follows this ADR's attribution, provenance, and modified-file requirements.
- M3 implementation may target only the named synthetic repository after the operator completes
  the external Docker and GitHub App setup.
- The M3 live demonstration remains unavailable until that external setup is verified; this ADR is
  a prerequisite record, not evidence that a worker, App, or scratch repository is operational.
- Independent verification, automated repair, automatic merge, production deployment, multiple
  repositories, a second agent backend, GitHub App creation, Docker installation, and live
  repository mutation remain out of scope for this change.

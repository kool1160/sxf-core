# Content-addressed evidence byte store

## Scope

`Sxf.Evidence` is the M3 control-plane boundary for immutable local evidence bytes. It connects
actual bytes to the existing durable `evidence_references` and transition-evidence associations
without starting a workspace, container, repository command, agent, GitHub operation, verifier, or
repair loop.

The public operations are:

```elixir
Sxf.Evidence.put(attrs, source)
Sxf.Evidence.get(evidence_id)
Sxf.Evidence.verify(evidence_id)
Sxf.Evidence.audit()
```

`source` may be an in-memory binary, `{:bytes, binary}`, or `{:file, path}`. File sources must be
regular files; directories, devices, and symbolic links are rejected. Reads and writes are
streamed in fixed chunks, and input above the platform-configured byte limit is rejected.

## Durable attribution

`put/2` requires:

- task ID and optional task-owned attempt ID;
- producer actor ID;
- evidence kind and media type;
- finalization time;
- correlation ID;
- task-scoped idempotency key;
- an explicit `redacted: true` assertion from the trusted control-plane producer; and
- optional JSON domain metadata of at most 64 KiB.

The caller cannot supply the content hash, byte size, or storage URI. SXF derives the SHA-256 and
exact size from the accepted bytes and persists the canonical URI `sha256://<lowercase-sha256>`.
The durable request fingerprint covers every accepted semantic input, including the derived byte
identity. Exact replay returns the original reference. Reuse of the task/idempotency identity with
different bytes or attribution is an explicit conflict.

One content address may support independently attributable references for different tasks or
attempts. Physical bytes are deduplicated; durable evidence ownership is not.

## Storage and finalization

The configured root contains:

```text
<root>/
  tmp/
  blobs/
    sha256/
      <first-two-digest-characters>/
        <complete-digest>
```

`put/2` writes a unique temporary file, enforces the byte limit while hashing, flushes it, and
publishes it with a same-filesystem atomic rename. It never overwrites an existing content address.
If the address already exists, SXF hashes and sizes the existing regular file before reuse.

The evidence-reference insert runs through an immediate SQLite transaction after ownership is
validated. Finalized reference rows are protected from update and deletion by database triggers.
Temporary files are removed on every returned path.

SQLite and the local filesystem are not one transactional resource. A process or database failure
after a new blob is published but before its reference commits may leave an unreferenced blob. SXF
does not delete it speculatively because another concurrent reference may own the same content.
`audit/0` reports such orphans deterministically. It never converts an orphan into evidence or
deletes bytes.

## Verification and transition authority

`verify/1` and `get/1` require all of the following:

- a finalized durable reference;
- a canonical URI matching its SHA-256;
- a regular blob at the derived path;
- an exact content-hash match; and
- an exact byte-size match.

`get/1` returns bytes only after those checks pass. Task transitions re-run the same verification
for every proposed evidence attachment inside the durable transition command. Missing, altered,
oversized, non-regular, or inconsistent bytes return an integrity failure and cannot satisfy the
`check_result` or later evidence gates. A workspace path, model message, unfinalized row, or metadata
claim alone is not evidence.

`audit/0` inspects all durable references and the local content inventory. It returns sorted
verified, missing, corrupt, invalid, and orphan results without changing either store.

## Configuration and custody

Development defaults to `var/evidence`; tests use `var/evidence_test`. Production requires an
explicit `SXF_EVIDENCE_PATH` alongside `SXF_DATABASE_PATH`. The default maximum artifact size is
16 MiB and is platform-owned configuration.

Evidence bytes are durable control-plane data. Workers must not receive the store root or write
directly to content addresses. Producers must redact secrets before calling `put/2`; the byte store
does not transform content because doing so would make the derived hash describe different bytes.
Unredacted evidence is rejected rather than retained.
Private keys, installation tokens, authorization headers, broad credentials, and production data
remain prohibited evidence content.

## Recovery and deferred work

The store has no in-memory authority. A Repo or control-plane restart reconstructs the reference
from SQLite and verifies the same bytes under the configured root. Backup and restoration must
eventually snapshot the SQLite database and evidence root as one recovery set.

Retention deletion, garbage collection, remote/object storage, encryption-at-rest policy,
coordinated backup tooling, workspace collection, command execution, agent output collection,
GitHub result production, independent verification, and repair are deferred. There is intentionally
no evidence-delete API in M3.

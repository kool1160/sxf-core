defmodule Sxf.EvidenceTest do
  use Sxf.DataCase, async: false

  alias Sxf.Evidence
  alias Sxf.Evidence.Error
  alias Sxf.Repo

  alias Sxf.Tasks.{
    Blocker,
    Budget,
    EvidenceReference,
    EventEvidenceReference,
    ExecutionEvent,
    ExternalActionOutboxReference,
    ExternalEventInboxReference,
    RetrySchedule,
    Task,
    TaskAttempt,
    TransitionEvent,
    UsageEntry,
    WorkerLease
  }

  setup do
    previous = Application.fetch_env!(:sxf_core, :evidence_store)

    root =
      Path.join(
        System.tmp_dir!(),
        "sxf-evidence-test-#{Ecto.UUID.generate()}"
      )

    Application.put_env(:sxf_core, :evidence_store, root: root, max_bytes: 1_024)

    on_exit(fn ->
      Application.put_env(:sxf_core, :evidence_store, previous)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "put derives immutable content identity and get returns verified bytes", %{root: root} do
    fixture = domain_fixture()
    bytes = "deterministic command output\n"
    attrs = evidence_attrs(fixture, "put-get")

    assert {:ok, %{reference: reference, idempotent?: false}} =
             Evidence.put(attrs, bytes)

    digest = sha256(bytes)
    assert reference.sha256 == digest
    assert reference.byte_size == byte_size(bytes)
    assert reference.storage_uri == "sha256://#{digest}"
    assert reference.finalized_at == attrs.finalized_at
    assert reference.correlation_id == attrs.correlation_id
    assert reference.redacted
    assert reference.request_fingerprint =~ ~r/\A[0-9a-f]{64}\z/

    path = blob_path(root, digest)
    assert File.read!(path) == bytes
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(path)

    assert {:ok, %{reference: loaded, bytes: ^bytes, verification: verification}} =
             Evidence.get(reference.id)

    assert loaded.id == reference.id
    assert verification.status == :verified

    assert_raise Exqlite.Error, fn ->
      reference
      |> Ecto.Changeset.change(kind: "changed")
      |> Repo.update!()
    end

    assert_raise Exqlite.Error, fn -> Repo.delete!(reference) end
    assert Repo.get!(EvidenceReference, reference.id).kind == attrs.kind
  end

  test "exact replay returns one reference and changed accepted input conflicts" do
    fixture = domain_fixture()
    attrs = evidence_attrs(fixture, "replay")
    other_actor = actor_fixture("worker", "other-evidence-producer")
    attempt = attempt_fixture(fixture.task)

    assert {:ok, %{reference: first, idempotent?: false}} = Evidence.put(attrs, "same")
    assert {:ok, %{reference: second, idempotent?: true}} = Evidence.put(attrs, {:bytes, "same"})
    assert first.id == second.id

    assert {:error, %Error{code: :idempotency_conflict}} =
             Evidence.put(attrs, "different")

    mutations = [
      Map.put(attrs, :id, uuid()),
      Map.put(attrs, :attempt_id, attempt.id),
      %{attrs | producer_actor_id: other_actor.id},
      %{attrs | kind: "agent_output"},
      %{attrs | media_type: "application/json"},
      %{attrs | finalized_at: DateTime.add(attrs.finalized_at, 1, :second)},
      %{attrs | correlation_id: uuid()},
      %{attrs | metadata: %{changed: true}}
    ]

    Enum.each(mutations, fn changed ->
      assert {:error, %Error{code: :idempotency_conflict}} =
               Evidence.put(changed, "same")
    end)

    assert Repo.aggregate(EvidenceReference, :count) == 1
  end

  test "identical bytes deduplicate physically while retaining independent attribution", %{
    root: root
  } do
    first = domain_fixture()
    second = domain_fixture()
    bytes = "shared immutable bytes"

    assert {:ok, %{reference: first_reference}} =
             Evidence.put(evidence_attrs(first, "dedupe-first"), bytes)

    assert {:ok, %{reference: second_reference}} =
             Evidence.put(evidence_attrs(second, "dedupe-second"), bytes)

    refute first_reference.id == second_reference.id
    refute first_reference.task_id == second_reference.task_id
    assert first_reference.storage_uri == second_reference.storage_uri
    assert Repo.aggregate(EvidenceReference, :count) == 2

    path = blob_path(root, first_reference.sha256)
    assert File.ls!(Path.dirname(path)) == [first_reference.sha256]
    assert File.read!(path) == bytes
  end

  test "file sources are bounded and rejected inputs leave no reference or temporary file", %{
    root: root
  } do
    fixture = domain_fixture()
    source = Path.join(root, "source.txt")
    File.mkdir_p!(root)
    File.write!(source, "file-backed evidence")

    assert {:ok, %{reference: reference}} =
             Evidence.put(evidence_attrs(fixture, "file"), {:file, source})

    assert {:ok, %{bytes: "file-backed evidence"}} = Evidence.get(reference.id)

    assert {:error, %Error{code: :evidence_too_large}} =
             Evidence.put(evidence_attrs(fixture, "too-large"), String.duplicate("x", 1_025))

    assert {:error, %Error{code: :actor_not_found}} =
             fixture
             |> evidence_attrs("missing-actor")
             |> Map.put(:producer_actor_id, uuid())
             |> Evidence.put("must not be staged")

    assert {:error, %Error{code: :unredacted_evidence}} =
             Evidence.put(
               %{evidence_attrs(fixture, "unredacted") | redacted: false},
               "not accepted"
             )

    assert {:error, %Error{code: :unsupported_attributes}} =
             fixture
             |> evidence_attrs("caller-hash")
             |> Map.put(:sha256, String.duplicate("a", 64))
             |> Evidence.put("caller cannot choose identity")

    assert Repo.aggregate(EvidenceReference, :count) == 1
    assert Path.wildcard(Path.join([root, "tmp", "*"])) == []
  end

  test "put creates no task, execution, inbox, or outbox authority" do
    fixture = domain_fixture()

    assert {:ok, %{reference: _reference}} =
             Evidence.put(evidence_attrs(fixture, "zero-side-effects"), "evidence only")

    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 1
    assert Repo.aggregate(EvidenceReference, :count) == 1
    assert Repo.aggregate(TaskAttempt, :count) == 0
    assert Repo.aggregate(WorkerLease, :count) == 0
    assert Repo.aggregate(RetrySchedule, :count) == 0
    assert Repo.aggregate(Blocker, :count) == 0
    assert Repo.aggregate(Budget, :count) == 0
    assert Repo.aggregate(UsageEntry, :count) == 0
    assert Repo.aggregate(ExecutionEvent, :count) == 0
    assert Repo.aggregate(ExternalEventInboxReference, :count) == 0
    assert Repo.aggregate(ExternalActionOutboxReference, :count) == 0
  end

  test "database unavailability returns a structured error without staging bytes", %{root: root} do
    fixture = domain_fixture()
    previous_repo = Repo.put_dynamic_repo(:missing_evidence_repo)

    try do
      assert {:error, %Error{code: :database_failure}} =
               Evidence.put(evidence_attrs(fixture, "database-down"), "not persisted")
    after
      Repo.put_dynamic_repo(previous_repo)
    end

    assert Repo.aggregate(EvidenceReference, :count) == 0
    assert Path.wildcard(Path.join([root, "tmp", "*"])) == []
  end

  test "concurrent exact puts create one durable reference" do
    fixture = domain_fixture()
    attrs = evidence_attrs(fixture, "concurrent")
    parent = self()

    callers =
      for suffix <- ["a", "b"] do
        Elixir.Task.async(fn ->
          send(parent, {:ready, suffix})

          receive do
            :put -> Evidence.put(attrs, "one result")
          end
        end)
      end

    assert_receive {:ready, "a"}
    assert_receive {:ready, "b"}
    Enum.each(callers, &send(&1.pid, :put))

    results = Enum.map(callers, &Elixir.Task.await(&1, 10_000))
    assert Enum.all?(results, &match?({:ok, %{reference: %EvidenceReference{}}}, &1))

    assert Enum.sort(Enum.map(results, fn {:ok, result} -> result.idempotent? end)) == [
             false,
             true
           ]

    assert Repo.aggregate(EvidenceReference, :count) == 1
  end

  test "missing or corrupt bytes fail verification and cannot satisfy a transition gate", %{
    root: root
  } do
    fixture = domain_fixture()
    task = advance_to_ci_running(fixture)

    assert {:ok, %{reference: reference}} =
             Evidence.put(
               evidence_attrs(fixture, "transition", %{kind: "check_result"}),
               "passed"
             )

    File.write!(blob_path(root, reference.sha256), "tampered")

    assert {:error, %Error{code: :content_hash_mismatch}} = Evidence.verify(reference.id)

    event_count = Repo.aggregate(TransitionEvent, :count)

    assert {:error, :evidence_integrity_failure} =
             transition(task, fixture.system_actor, "VERIFYING", 11, %{
               evidence_reference_ids: [reference.id]
             })

    assert Repo.get!(Task, task.id).state == "CI_RUNNING"
    assert Repo.aggregate(TransitionEvent, :count) == event_count
    assert Repo.aggregate(EventEvidenceReference, :count) == 0

    File.rm!(blob_path(root, reference.sha256))
    assert {:error, %Error{code: :missing_blob}} = Evidence.verify(reference.id)
  end

  test "verified bytes attach to the existing transition evidence boundary" do
    fixture = domain_fixture()
    task = advance_to_ci_running(fixture)

    assert {:ok, %{reference: reference}} =
             Evidence.put(evidence_attrs(fixture, "attach", %{kind: "check_result"}), "passed")

    assert {:ok, %{task: verifying, event: event}} =
             transition(task, fixture.system_actor, "VERIFYING", 11, %{
               evidence_reference_ids: [reference.id]
             })

    assert verifying.state == "VERIFYING"

    assert Repo.get_by!(EventEvidenceReference,
             transition_event_id: event.id,
             evidence_reference_id: reference.id
           )
  end

  test "audit reports verified, missing, corrupt, and orphan content deterministically", %{
    root: root
  } do
    fixture = domain_fixture()

    {:ok, %{reference: verified}} =
      Evidence.put(evidence_attrs(fixture, "audit-verified"), "verified")

    {:ok, %{reference: missing}} =
      Evidence.put(evidence_attrs(fixture, "audit-missing"), "missing")

    {:ok, %{reference: corrupt}} =
      Evidence.put(evidence_attrs(fixture, "audit-corrupt"), "corrupt")

    File.rm!(blob_path(root, missing.sha256))
    File.write!(blob_path(root, corrupt.sha256), "changed")

    orphan_digest = sha256("orphan")
    orphan_path = blob_path(root, orphan_digest)
    File.mkdir_p!(Path.dirname(orphan_path))
    File.write!(orphan_path, "orphan")

    assert {:ok, audit} = Evidence.audit()
    assert audit.references == 3
    assert audit.verified == [verified.id]
    assert audit.missing == [missing.id]
    assert audit.corrupt == [corrupt.id]
    assert audit.invalid == []

    assert audit.orphaned == [
             Path.relative_to(orphan_path, root)
           ]
  end

  defp evidence_attrs(fixture, suffix, overrides \\ %{}) do
    Map.merge(
      %{
        task_id: fixture.task.id,
        producer_actor_id: fixture.system_actor.id,
        kind: "command_output",
        media_type: "text/plain",
        finalized_at: DateTime.add(base_time(), 1, :second),
        correlation_id: uuid(),
        idempotency_key: "evidence:#{suffix}",
        redacted: true,
        metadata: %{source: "test"}
      },
      overrides
    )
  end

  defp advance_to_ci_running(fixture) do
    {:ok, %{task: specified}} =
      transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)

    {:ok, %{task: planned}} = transition(specified, fixture.system_actor, "PLANNED", 2)
    {:ok, %{task: ready}} = transition(planned, fixture.system_actor, "READY", 3)
    attempt = attempt_fixture(ready)
    budget_fixture(ready, %{attempt_id: attempt.id})
    lease_fixture(ready, attempt)

    {:ok, %{task: implementing}} =
      transition(ready, fixture.worker_actor, "IMPLEMENTING", 4, %{attempt_id: attempt.id})

    {:ok, %{task: ci_running}} =
      transition(implementing, fixture.system_actor, "CI_RUNNING", 5, %{
        attempt_id: attempt.id
      })

    ci_running
  end

  defp blob_path(root, digest) do
    Path.join([root, "blobs", "sha256", binary_part(digest, 0, 2), digest])
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

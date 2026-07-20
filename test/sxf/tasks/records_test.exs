defmodule Sxf.Tasks.RecordsTest do
  use Sxf.DataCase, async: false

  alias Sxf.Repo
  alias Sxf.Tasks
  alias Sxf.Tasks.ExternalActionOutboxReference
  alias Sxf.Tasks.ExternalEventInboxReference
  alias Sxf.Tasks.HumanDecision
  alias Sxf.Tasks.TaskAttempt

  test "attempt commands are stable and idempotent without naming a concrete agent provider" do
    fixture = domain_fixture()

    assert {:error, :attempt_not_allowed_in_task_state} =
             Tasks.create_attempt(%{
               task_id: fixture.task.id,
               sequence: 1,
               idempotency_key: "attempt:too-early"
             })

    {:ok, %{task: task}} = transition(fixture.task, fixture.system_actor, "SPECIFIED", 1)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "PLANNED", 2)
    {:ok, %{task: task}} = transition(task, fixture.system_actor, "READY", 3)

    attrs = %{
      id: uuid(),
      task_id: task.id,
      sequence: 1,
      status: "planned",
      backend: "backend-contract-v1",
      backend_session_id: "opaque-session-reference",
      idempotency_key: "attempt:one"
    }

    assert {:ok, %{attempt: attempt, idempotent?: false}} = Tasks.create_attempt(attrs)
    assert {:ok, %{attempt: replay, idempotent?: true}} = Tasks.create_attempt(attrs)
    assert replay.id == attempt.id
    assert attempt.backend == "backend-contract-v1"

    assert {:error, :idempotency_conflict} =
             Tasks.create_attempt(%{attrs | backend: "other-backend"})

    refute :codex_thread_id in TaskAttempt.__schema__(:fields)
    refute :github_issue_id in TaskAttempt.__schema__(:fields)
  end

  test "inbox and outbox references reserve idempotent durable integration boundaries" do
    fixture = domain_fixture()
    correlation_id = uuid()
    hash = String.duplicate("b", 64)

    inbox =
      %ExternalEventInboxReference{}
      |> ExternalEventInboxReference.changeset(%{
        id: uuid(),
        task_id: fixture.task.id,
        source: "provider-webhook",
        external_id: "delivery-123",
        payload_sha256: hash,
        status: "received",
        received_at: base_time(),
        correlation_id: correlation_id
      })
      |> Repo.insert!()

    outbox =
      %ExternalActionOutboxReference{}
      |> ExternalActionOutboxReference.changeset(%{
        id: uuid(),
        task_id: fixture.task.id,
        destination: "provider-api",
        action: "publish_status",
        payload_sha256: hash,
        status: "pending",
        available_at: base_time(),
        correlation_id: correlation_id,
        idempotency_key: "publish-status:#{fixture.task.id}:1"
      })
      |> Repo.insert!()

    assert inbox.external_id == "delivery-123"
    assert outbox.status == "pending"

    assert {:error, duplicate} =
             %ExternalEventInboxReference{}
             |> ExternalEventInboxReference.changeset(%{
               task_id: fixture.task.id,
               source: inbox.source,
               external_id: inbox.external_id,
               payload_sha256: hash,
               status: "received",
               received_at: base_time(),
               correlation_id: correlation_id
             })
             |> Repo.insert()

    assert errors_on(duplicate)
           |> Map.values()
           |> List.flatten()
           |> Enum.member?("has already been taken")
  end

  test "human decisions require a human actor and retain correlation and reason" do
    fixture = domain_fixture()
    decision = decision_fixture(fixture.task, fixture.human_actor, "approval")

    assert %HumanDecision{} = decision
    assert decision.actor_id == fixture.human_actor.id
    assert decision.reason == "explicit operator decision"
    assert Sxf.Identifiers.valid?(decision.correlation_id)

    replay_attrs = %{
      id: decision.id,
      task_id: decision.task_id,
      actor_id: decision.actor_id,
      kind: decision.kind,
      decision: decision.decision,
      reason: decision.reason,
      occurred_at: decision.occurred_at,
      correlation_id: decision.correlation_id,
      idempotency_key: decision.idempotency_key,
      target_type: decision.target_type,
      target_id: decision.target_id,
      target_action: decision.target_action
    }

    assert {:ok, %{decision: replay, idempotent?: true}} =
             Tasks.record_human_decision(replay_attrs)

    assert replay.id == decision.id

    assert {:error, :human_actor_required} =
             Tasks.record_human_decision(%{
               task_id: fixture.task.id,
               actor_id: fixture.system_actor.id,
               kind: "approval",
               decision: "approved",
               reason: "system cannot impersonate a human",
               occurred_at: base_time(),
               correlation_id: uuid(),
               idempotency_key: "invalid-system-approval",
               target_type: "transition",
               target_id: uuid(),
               target_action: "APPROVED"
             })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

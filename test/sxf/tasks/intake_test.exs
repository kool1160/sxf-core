defmodule Sxf.Tasks.IntakeTest do
  use Sxf.DataCase, async: false

  alias Sxf.Repo
  alias Sxf.Tasks
  alias Sxf.Tasks.ExternalEventInboxReference
  alias Sxf.Tasks.Project
  alias Sxf.Tasks.RepositoryRegistration
  alias Sxf.Tasks.Task
  alias Sxf.Tasks.TransitionEvent

  setup do
    project =
      %Project{}
      |> Project.changeset(%{id: uuid(), name: "GitHub intake"})
      |> Repo.insert!()

    repository_external_id = "R_#{System.unique_integer([:positive])}"

    repository =
      %RepositoryRegistration{}
      |> RepositoryRegistration.changeset(%{
        id: uuid(),
        project_id: project.id,
        provider: "github",
        external_id: repository_external_id,
        owner: "kool1160",
        name: "sxf-m3-scratch",
        clone_url: "https://github.com/kool1160/sxf-m3-scratch.git"
      })
      |> Repo.insert!()

    actor = actor_fixture("external_system", "github-app-intake")

    %{project: project, repository: repository, actor: actor}
  end

  test "normalization atomically persists one inbox observation, task, and creation event",
       fixture do
    attrs = intake_attrs(fixture)

    assert {:ok,
            %{
              inbox: inbox,
              task: task,
              event: event,
              task_created?: true,
              idempotent?: false
            }} = Tasks.normalize_external_issue(attrs)

    assert inbox.status == "processed"
    assert inbox.task_id == task.id
    assert inbox.source == "github"
    assert inbox.source_version == attrs.source_version
    assert inbox.payload_sha256 == attrs.payload_sha256
    assert inbox.request_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert inbox.processed_at == attrs.received_at

    assert task.project_id == fixture.project.id
    assert task.repository_registration_id == fixture.repository.id
    assert task.source_ref == attrs.issue_external_id
    assert task.title == attrs.title
    assert task.state == "DISCOVERED"
    assert task.transition_sequence == 1

    source = task.metadata["external_issue"]
    assert source["provider"] == "github"
    assert source["repository_external_id"] == fixture.repository.external_id
    assert source["issue_external_id"] == attrs.issue_external_id
    assert source["source_version"] == attrs.source_version
    assert source["body"] == attrs.body
    assert source["attributes"] == attrs.metadata

    assert event.task_id == task.id
    assert event.sequence == 1
    assert event.prior_state == nil
    assert event.resulting_state == "DISCOVERED"
    assert event.actor_id == fixture.actor.id
    assert event.reason_code == "external_issue_intake"

    assert Repo.aggregate(ExternalEventInboxReference, :count) == 1
    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 1
  end

  test "exact observation replay returns the original durable result without duplicate rows",
       fixture do
    attrs = intake_attrs(fixture)

    assert {:ok, first} = Tasks.normalize_external_issue(attrs)

    replay =
      attrs
      |> Map.put(:received_at, DateTime.add(attrs.received_at, 30, :second))
      |> Map.put(:correlation_id, uuid())

    assert {:ok, second} = Tasks.normalize_external_issue(replay)
    assert second.idempotent?
    assert second.task_created?
    assert second.inbox.id == first.inbox.id
    assert second.task.id == first.task.id
    assert second.event.id == first.event.id
    assert second.inbox.received_at == attrs.received_at

    assert Repo.aggregate(ExternalEventInboxReference, :count) == 1
    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 1
  end

  test "reusing an observation identity with changed semantic input conflicts", fixture do
    attrs = intake_attrs(fixture)
    other_actor = actor_fixture("external_system", "other-intake")
    assert {:ok, _} = Tasks.normalize_external_issue(attrs)

    mutations = [
      %{attrs | payload_sha256: String.duplicate("b", 64)},
      %{attrs | title: "Changed title"},
      %{attrs | body: "Changed body"},
      %{attrs | actor_id: other_actor.id},
      put_in(attrs, [:metadata, "issue_number"], 99)
    ]

    for changed <- mutations do
      assert {:error, :idempotency_conflict} = Tasks.normalize_external_issue(changed)
    end

    assert Repo.aggregate(ExternalEventInboxReference, :count) == 1
    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 1
  end

  test "a later source version records a new inbox observation and reconciles the same task",
       fixture do
    first_attrs = intake_attrs(fixture)
    assert {:ok, first} = Tasks.normalize_external_issue(first_attrs)

    later_attrs = %{
      first_attrs
      | source_version: "2026-07-27T16:01:00Z",
        payload_sha256: String.duplicate("c", 64),
        title: "Updated untrusted title",
        body: "Updated untrusted body",
        received_at: DateTime.add(first_attrs.received_at, 60, :second),
        correlation_id: uuid()
    }

    assert {:ok, later} = Tasks.normalize_external_issue(later_attrs)
    refute later.idempotent?
    refute later.task_created?
    assert later.task.id == first.task.id
    assert later.event.id == first.event.id
    refute later.inbox.id == first.inbox.id
    assert later.inbox.task_id == first.task.id

    assert Repo.aggregate(ExternalEventInboxReference, :count) == 2
    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 1
    assert Repo.get!(Task, first.task.id).title == first_attrs.title
  end

  test "stable issue identity is scoped to the registered repository", fixture do
    other_project =
      %Project{}
      |> Project.changeset(%{id: uuid(), name: "Other"})
      |> Repo.insert!()

    other_repository =
      %RepositoryRegistration{}
      |> RepositoryRegistration.changeset(%{
        id: uuid(),
        project_id: other_project.id,
        provider: "github",
        external_id: "R_other_#{System.unique_integer([:positive])}",
        owner: "kool1160",
        name: "other",
        clone_url: "https://github.com/kool1160/other.git"
      })
      |> Repo.insert!()

    first_attrs = intake_attrs(fixture)
    assert {:ok, first} = Tasks.normalize_external_issue(first_attrs)

    other_attrs =
      fixture
      |> Map.put(:project, other_project)
      |> Map.put(:repository, other_repository)
      |> intake_attrs()
      |> Map.put(:issue_external_id, first_attrs.issue_external_id)

    assert {:ok, other} = Tasks.normalize_external_issue(other_attrs)
    refute other.task.id == first.task.id
    assert other.task.source_ref == first.task.source_ref
    assert Repo.aggregate(Task, :count) == 2
  end

  test "unknown repository, unauthorized actor, and inactive project leave no partial writes",
       fixture do
    attrs = intake_attrs(fixture)

    assert {:error, :repository_registration_not_found} =
             Tasks.normalize_external_issue(%{attrs | repository_external_id: "R_missing"})

    human = actor_fixture("human", "not-an-intake-actor")

    assert {:error, :intake_actor_required} =
             Tasks.normalize_external_issue(%{attrs | actor_id: human.id})

    fixture.project
    |> Project.changeset(%{status: "archived"})
    |> Repo.update!()

    assert {:error, :project_not_active} = Tasks.normalize_external_issue(attrs)

    assert Repo.aggregate(ExternalEventInboxReference, :count) == 0
    assert Repo.aggregate(Task, :count) == 0
    assert Repo.aggregate(TransitionEvent, :count) == 0
  end

  test "invalid and excessive untrusted inputs fail before persistence", fixture do
    attrs = intake_attrs(fixture)

    invalid = [
      %{attrs | correlation_id: "not-a-uuid"},
      %{attrs | actor_id: "not-a-uuid"},
      %{attrs | payload_sha256: "not-a-hash"},
      %{attrs | payload_sha256: <<255, 255>>},
      %{attrs | title: <<255, 255>>},
      %{attrs | body: <<255, 255>>},
      %{attrs | title: String.duplicate("t", 501)},
      %{attrs | body: String.duplicate("b", 65_537)},
      %{attrs | metadata: %{"invalid" => self()}},
      %{attrs | metadata: nested_metadata(10)}
    ]

    for command <- invalid do
      assert {:error, {:invalid_command_field, _field}} =
               Tasks.normalize_external_issue(command)
    end

    assert Repo.aggregate(ExternalEventInboxReference, :count) == 0
    assert Repo.aggregate(Task, :count) == 0
    assert Repo.aggregate(TransitionEvent, :count) == 0
  end

  test "untrusted metadata cannot overwrite platform-owned source identity", fixture do
    attrs =
      intake_attrs(fixture, %{
        "external_issue" => %{
          "provider" => "evil",
          "repository_external_id" => "R_evil",
          "issue_external_id" => "I_evil"
        },
        "authority" => "expanded"
      })

    assert {:ok, %{task: task}} = Tasks.normalize_external_issue(attrs)
    source = task.metadata["external_issue"]

    assert source["provider"] == "github"
    assert source["repository_external_id"] == fixture.repository.external_id
    assert source["issue_external_id"] == attrs.issue_external_id
    assert source["attributes"] == attrs.metadata
  end

  test "database uniqueness rejects a second task for one repository source identity", fixture do
    attrs = intake_attrs(fixture)
    assert {:ok, %{task: task}} = Tasks.normalize_external_issue(attrs)

    duplicate = %{
      id: uuid(),
      project_id: fixture.project.id,
      repository_registration_id: fixture.repository.id,
      title: "Duplicate",
      source_ref: task.source_ref,
      actor_id: fixture.actor.id,
      reason: "duplicate source",
      occurred_at: DateTime.add(attrs.received_at, 1, :second),
      correlation_id: uuid(),
      idempotency_key: "duplicate-source"
    }

    assert {:error, %Ecto.Changeset{} = changeset} = Tasks.create_task(duplicate)
    assert {"has already been taken", _} = Keyword.fetch!(changeset.errors, :source_ref)
    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(TransitionEvent, :count) == 1
  end

  defp intake_attrs(fixture, metadata \\ %{"issue_number" => 42}) do
    %{
      provider: "github",
      repository_external_id: fixture.repository.external_id,
      issue_external_id: "I_#{System.unique_integer([:positive])}",
      source_version: "2026-07-27T16:00:00Z",
      payload_sha256: String.duplicate("a", 64),
      title: "Implement one bounded task",
      body: "Untrusted issue body",
      actor_id: fixture.actor.id,
      received_at: ~U[2026-07-27 16:00:01.000000Z],
      correlation_id: uuid(),
      metadata: metadata
    }
  end

  defp nested_metadata(0), do: %{"value" => true}
  defp nested_metadata(depth), do: %{"nested" => nested_metadata(depth - 1)}
end

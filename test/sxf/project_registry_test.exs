defmodule Sxf.ProjectRegistryTest do
  use Sxf.DataCase, async: false

  alias Sxf.ProjectManifest.Error
  alias Sxf.ProjectManifest.Policy
  alias Sxf.ProjectRegistry

  alias Sxf.Tasks.{
    Blocker,
    Budget,
    ExternalActionOutboxReference,
    ExternalEventInboxReference,
    Project,
    RepositoryRegistration,
    RetrySchedule,
    Task,
    TaskAttempt,
    TransitionEvent,
    UsageEntry,
    WorkerLease
  }

  @registered_at ~U[2026-07-28 11:00:00.000000Z]

  setup do
    %{actor: actor_fixture("system", "project-registry")}
  end

  test "valid YAML atomically persists the normalized policy-bounded registration", fixture do
    attrs = registration_attrs(fixture)

    assert {:ok,
            %{
              project: project,
              repository: repository,
              manifest: manifest,
              idempotent?: false
            }} = ProjectRegistry.register_repository(attrs)

    assert project.name == "SXF M3 Scratch"
    assert project.status == "active"

    assert repository.project_id == project.id
    assert repository.provider == attrs.provider
    assert repository.external_id == attrs.external_id
    assert repository.owner == attrs.owner
    assert repository.name == attrs.name
    assert repository.clone_url == attrs.clone_url
    assert repository.default_branch == attrs.default_branch
    assert repository.manifest_schema_version == "0.1"
    assert repository.normalized_manifest == manifest
    assert repository.raw_manifest_sha256 == sha256(attrs.manifest_content)
    assert repository.registration_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert repository.registered_by_actor_id == fixture.actor.id
    assert repository.registered_at == attrs.registered_at
    assert repository.registration_correlation_id == attrs.correlation_id

    assert manifest["commands"]["install"] == "mix deps.get"
    assert manifest["budgets"]["maxCostMicrousd"] == 2_000_000
    assert manifest["autonomy"]["createBranches"]
    assert manifest["restrictions"]["allowedNetworkDomains"] == ["github.com"]
    assert "expose-secrets" in manifest["restrictions"]["prohibitedActions"]

    assert {:ok, lookup} =
             ProjectRegistry.lookup_repository(attrs.provider, attrs.external_id)

    assert lookup.project.id == project.id
    assert lookup.repository.id == repository.id
    assert lookup.manifest == manifest
    refute lookup.idempotent?
  end

  test "equivalent JSON representation is a semantic replay", fixture do
    yaml_attrs = registration_attrs(fixture)
    assert {:ok, first} = ProjectRegistry.register_repository(yaml_attrs)

    json_attrs =
      yaml_attrs
      |> Map.put(:manifest_content, Jason.encode!(manifest_map()))
      |> Map.put(:manifest_format, :json)
      |> Map.put(:registered_at, DateTime.add(@registered_at, 30, :second))
      |> Map.put(:correlation_id, uuid())

    assert {:ok, replay} = ProjectRegistry.register_repository(json_attrs)
    assert replay.idempotent?
    assert replay.project.id == first.project.id
    assert replay.repository.id == first.repository.id
    assert replay.manifest == first.manifest
    assert replay.repository.raw_manifest_sha256 == sha256(yaml_attrs.manifest_content)

    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(RepositoryRegistration, :count) == 1
  end

  test "exact replay ignores fresh timestamp and correlation envelopes", fixture do
    attrs = registration_attrs(fixture)
    assert {:ok, first} = ProjectRegistry.register_repository(attrs)

    replay_attrs = %{
      attrs
      | registered_at: DateTime.add(attrs.registered_at, 60, :second),
        correlation_id: uuid()
    }

    assert {:ok, replay} = ProjectRegistry.register_repository(replay_attrs)
    assert replay.idempotent?
    assert replay.repository.id == first.repository.id
    assert replay.repository.registered_at == attrs.registered_at
    assert replay.repository.registration_correlation_id == attrs.correlation_id
  end

  test "changed normalized manifest content conflicts without partial writes", fixture do
    attrs = registration_attrs(fixture)
    assert {:ok, first} = ProjectRegistry.register_repository(attrs)

    changed_manifest =
      manifest_map()
      |> put_in(["commands", "test"], "mix test --changed")
      |> Jason.encode!()

    assert {:error, :registration_conflict} =
             ProjectRegistry.register_repository(%{
               attrs
               | manifest_content: changed_manifest,
                 manifest_format: :json
             })

    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(RepositoryRegistration, :count) == 1
    assert Repo.one!(RepositoryRegistration).id == first.repository.id
  end

  test "changed repository metadata conflicts for every accepted field", fixture do
    attrs = registration_attrs(fixture)
    assert {:ok, first} = ProjectRegistry.register_repository(attrs)

    changes = [
      %{attrs | owner: "renamed-owner"},
      %{attrs | name: "renamed-repository"},
      %{attrs | clone_url: "https://github.com/kool1160/renamed.git"},
      %{attrs | default_branch: "trunk"},
      %{attrs | actor_id: actor_fixture("human", "other-registrar").id}
    ]

    for changed <- changes do
      assert {:error, :registration_conflict} =
               ProjectRegistry.register_repository(changed)
    end

    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(RepositoryRegistration, :count) == 1
    assert Repo.one!(RepositoryRegistration).id == first.repository.id
  end

  test "malformed, unsupported, and policy-conflicting manifests roll back completely", fixture do
    attrs = registration_attrs(fixture)

    rejected = [
      %{attrs | manifest_content: "project: [", manifest_format: :yaml},
      %{
        attrs
        | manifest_content:
            manifest_map()
            |> Map.put("schemaVersion", "9.9")
            |> Jason.encode!(),
          manifest_format: :json
      },
      %{attrs | platform_policy: Policy.new()}
    ]

    for command <- rejected do
      assert {:error, [%Error{} | _]} = ProjectRegistry.register_repository(command)
      assert Repo.aggregate(Project, :count) == 0
      assert Repo.aggregate(RepositoryRegistration, :count) == 0
    end
  end

  test "missing, malformed, and unknown actors are rejected without persistence", fixture do
    attrs = registration_attrs(fixture)

    assert {:error, {:missing_command_field, :actor_id}} =
             attrs
             |> Map.delete(:actor_id)
             |> ProjectRegistry.register_repository()

    assert {:error, {:invalid_command_field, :actor_id}} =
             ProjectRegistry.register_repository(%{attrs | actor_id: "not-a-uuid"})

    assert {:error, :actor_not_found} =
             ProjectRegistry.register_repository(%{attrs | actor_id: uuid()})

    assert Repo.aggregate(Project, :count) == 0
    assert Repo.aggregate(RepositoryRegistration, :count) == 0
  end

  test "manifest commands are returned unchanged but never executed", fixture do
    marker =
      Path.join(
        System.tmp_dir!(),
        "sxf-registry-command-marker-#{System.unique_integer([:positive])}"
      )

    File.rm(marker)
    on_exit(fn -> File.rm(marker) end)

    command = "echo registry-command-executed > #{marker}"

    manifest_content =
      manifest_map()
      |> put_in(["commands", "install"], command)
      |> Jason.encode!()

    attrs =
      fixture
      |> registration_attrs()
      |> Map.put(:manifest_content, manifest_content)
      |> Map.put(:manifest_format, :json)

    assert {:ok, result} = ProjectRegistry.register_repository(attrs)
    assert result.manifest["commands"]["install"] == command
    refute File.exists?(marker)
  end

  test "registration creates no task, workflow, inbox, outbox, or execution records", fixture do
    assert {:ok, _result} =
             fixture
             |> registration_attrs()
             |> ProjectRegistry.register_repository()

    assert Repo.aggregate(Task, :count) == 0
    assert Repo.aggregate(TransitionEvent, :count) == 0
    assert Repo.aggregate(ExternalEventInboxReference, :count) == 0
    assert Repo.aggregate(ExternalActionOutboxReference, :count) == 0
    assert Repo.aggregate(TaskAttempt, :count) == 0
    assert Repo.aggregate(WorkerLease, :count) == 0
    assert Repo.aggregate(RetrySchedule, :count) == 0
    assert Repo.aggregate(Blocker, :count) == 0
    assert Repo.aggregate(Budget, :count) == 0
    assert Repo.aggregate(UsageEntry, :count) == 0
  end

  test "invalid identities and metadata fail before persistence", fixture do
    attrs = registration_attrs(fixture)

    rejected = [
      Map.delete(attrs, :provider),
      %{attrs | provider: ""},
      %{attrs | external_id: ""},
      %{attrs | owner: ""},
      %{attrs | name: ""},
      %{attrs | clone_url: ""},
      %{attrs | default_branch: ""},
      %{attrs | manifest_content: <<255, 255>>},
      %{attrs | registered_at: "not-a-time"},
      %{attrs | correlation_id: "not-a-uuid"}
    ]

    for command <- rejected do
      assert {:error, _reason} = ProjectRegistry.register_repository(command)
      assert Repo.aggregate(Project, :count) == 0
      assert Repo.aggregate(RepositoryRegistration, :count) == 0
    end
  end

  test "a database insert failure rolls the project insertion back", fixture do
    Repo.query!("""
    CREATE TEMP TRIGGER reject_project_registration
    BEFORE INSERT ON repository_registrations
    BEGIN
      SELECT RAISE(ABORT, 'forced project registry failure');
    END
    """)

    try do
      assert {:error, {:database_error, message}} =
               fixture
               |> registration_attrs()
               |> ProjectRegistry.register_repository()

      assert message =~ "forced project registry failure"
      assert Repo.aggregate(Project, :count) == 0
      assert Repo.aggregate(RepositoryRegistration, :count) == 0
    after
      Repo.query!("DROP TRIGGER reject_project_registration")
    end
  end

  test "lookup rejects invalid or unknown durable identities" do
    assert {:error, {:invalid_command_field, :provider}} =
             ProjectRegistry.lookup_repository("", "R_1")

    assert {:error, {:invalid_command_field, :external_id}} =
             ProjectRegistry.lookup_repository("github", "")

    assert {:error, :registration_not_found} =
             ProjectRegistry.lookup_repository("github", "R_missing")
  end

  defp registration_attrs(fixture) do
    %{
      provider: "github",
      external_id: "R_#{System.unique_integer([:positive])}",
      owner: "kool1160",
      name: "sxf-m3-scratch",
      clone_url: "https://github.com/kool1160/sxf-m3-scratch.git",
      default_branch: "main",
      manifest_content: manifest_yaml(),
      manifest_format: :yaml,
      platform_policy: platform_policy(),
      actor_id: fixture.actor.id,
      registered_at: @registered_at,
      correlation_id: uuid()
    }
  end

  defp platform_policy do
    Policy.new(
      allowed_autonomy: ["createBranches", "openPullRequests"],
      allowed_network_domains: ["github.com"],
      minimum_coverage_percent: 75,
      max_cost_microusd: 2_000_000,
      max_runtime_minutes: 15,
      max_agent_turns: 20,
      max_repair_cycles: 0
    )
  end

  defp manifest_map do
    %{
      "schemaVersion" => "0.1",
      "project" => %{
        "name" => "SXF M3 Scratch",
        "description" => "Synthetic repository for the bounded M3 demonstration.",
        "status" => "existing",
        "documentationRoot" => "docs"
      },
      "commands" => %{
        "install" => "mix deps.get",
        "test" => "mix test"
      },
      "autonomy" => %{
        "createIssues" => false,
        "createBranches" => true,
        "openPullRequests" => true,
        "mergeToDefault" => false,
        "deployToStaging" => false,
        "deployToProduction" => false
      },
      "verification" => %{
        "independent" => true,
        "requireDifferentBackend" => false,
        "requireDeterministicChecks" => true,
        "requireUiEvidence" => false,
        "minimumCoveragePercent" => 80
      },
      "budgets" => %{
        "maxCostUsd" => 2,
        "maxRuntimeMinutes" => 15,
        "maxAgentTurns" => 20,
        "maxRepairCycles" => 0
      },
      "restrictions" => %{
        "protectedPaths" => [".github/"],
        "prohibitedActions" => ["modify-billing"],
        "allowedNetworkDomains" => ["github.com"]
      }
    }
  end

  defp manifest_yaml do
    """
    schemaVersion: "0.1"
    project:
      name: SXF M3 Scratch
      description: Synthetic repository for the bounded M3 demonstration.
      status: existing
      documentationRoot: docs
    commands:
      install: mix deps.get
      test: mix test
    autonomy:
      createIssues: false
      createBranches: true
      openPullRequests: true
      mergeToDefault: false
      deployToStaging: false
      deployToProduction: false
    verification:
      independent: true
      requireDifferentBackend: false
      requireDeterministicChecks: true
      requireUiEvidence: false
      minimumCoveragePercent: 80
    budgets:
      maxCostUsd: 2
      maxRuntimeMinutes: 15
      maxAgentTurns: 20
      maxRepairCycles: 0
    restrictions:
      protectedPaths:
        - .github/
      prohibitedActions:
        - modify-billing
      allowedNetworkDomains:
        - github.com
    """
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end

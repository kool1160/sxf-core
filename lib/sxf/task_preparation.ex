defmodule Sxf.TaskPreparation do
  @moduledoc """
  Durable manifest-gated promotion of one external issue task to `READY`.

  Preparation reads only accepted SQLite state. It pins the connected-project registration and
  latest processed issue observation, materializes one bounded task budget, and appends the legal
  lifecycle transitions in a single transaction. It never executes manifest commands or invokes
  repository, network, workspace, sandbox, agent, or GitHub mutation boundaries.
  """

  import Ecto.Query

  alias Sxf.Repo
  alias Sxf.Tasks.Actor
  alias Sxf.Tasks.Budget
  alias Sxf.Tasks.ExternalEventInboxReference
  alias Sxf.Tasks.Project
  alias Sxf.Tasks.RepositoryRegistration
  alias Sxf.Tasks.StateMachine
  alias Sxf.Tasks.Task
  alias Sxf.Tasks.TaskPreparation, as: Preparation
  alias Sxf.Tasks.TransitionEvent

  @m3_max_cost_microusd 2_000_000
  @m3_max_runtime_minutes 15
  @m3_max_agent_turns 20
  @m3_max_repair_cycles 0
  @m3_max_provider_retries 2

  @required_fields [:task_id, :actor_id, :prepared_at, :correlation_id, :idempotency_key]

  @doc "Prepares or idempotently replays one manifest-gated task promotion."
  def prepare(attrs) do
    with :ok <- require_fields(attrs, @required_fields),
         :ok <- validate_command(attrs) do
      transact(attrs, 1)
    end
  end

  @doc "Returns the immutable preparation contract and its task budget by durable task ID."
  def lookup(task_id) do
    if Sxf.Identifiers.valid?(task_id) do
      case Repo.get_by(Preparation, task_id: task_id) do
        nil -> {:error, :preparation_not_found}
        preparation -> preparation_result(preparation, true)
      end
    else
      {:error, {:invalid_command_field, :task_id}}
    end
  end

  defp prepare_in_transaction(attrs) do
    task = Repo.get(Task, attrs.task_id) || Repo.rollback(:task_not_found)
    actor = Repo.get(Actor, attrs.actor_id) || Repo.rollback(:actor_not_found)

    if actor.kind != "system" do
      Repo.rollback(:preparation_actor_required)
    end

    project = Repo.get(Project, task.project_id) || Repo.rollback(:project_not_found)

    if project.status != "active" do
      Repo.rollback(:project_not_active)
    end

    registration =
      Repo.get(RepositoryRegistration, task.repository_registration_id) ||
        Repo.rollback(:repository_registration_not_found)

    validate_registration_ownership(task, registration)
    manifest = validate_manifest_registration(registration)
    source = latest_source_observation(task, registration)
    contract = build_contract(task, registration, source, manifest)
    semantic_fingerprint = semantic_fingerprint(task, registration, source, actor, contract)

    case Repo.get_by(Preparation, task_id: task.id) do
      %Preparation{semantic_fingerprint: ^semantic_fingerprint} = preparation ->
        preparation_result(preparation, true) |> unwrap_or_rollback()

      %Preparation{} ->
        Repo.rollback(:preparation_conflict)

      nil ->
        create_preparation(
          task,
          registration,
          source,
          actor,
          manifest,
          contract,
          semantic_fingerprint,
          attrs
        )
    end
  end

  defp transact(attrs, lock_retries_remaining) do
    try do
      Repo.transaction(fn -> prepare_in_transaction(attrs) end)
      |> flatten_transaction()
    rescue
      exception in [DBConnection.ConnectionError, Ecto.ConstraintError, Exqlite.Error] ->
        if lock_retries_remaining > 0 and database_locked?(exception) do
          transact(attrs, lock_retries_remaining - 1)
        else
          {:error, {:database_error, Exception.message(exception)}}
        end
    end
  end

  defp create_preparation(
         task,
         registration,
         source,
         actor,
         manifest,
         contract,
         semantic_fingerprint,
         attrs
       ) do
    if task.state != "DISCOVERED" do
      Repo.rollback(:task_not_discovered)
    end

    if DateTime.compare(attrs.prepared_at, task.last_transition_at) == :lt do
      Repo.rollback(:out_of_order_preparation)
    end

    preparation =
      %Preparation{}
      |> Preparation.changeset(%{
        id: Sxf.Identifiers.generate(),
        project_id: task.project_id,
        task_id: task.id,
        repository_registration_id: registration.id,
        source_inbox_id: source.id,
        prepared_by_actor_id: actor.id,
        manifest_schema_version: registration.manifest_schema_version,
        registration_fingerprint: registration.registration_fingerprint,
        source_version: source.source_version,
        source_payload_sha256: source.payload_sha256,
        contract: contract,
        semantic_fingerprint: semantic_fingerprint,
        prepared_at: attrs.prepared_at,
        correlation_id: attrs.correlation_id,
        idempotency_key: attrs.idempotency_key
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    budget = create_budget(preparation, task, manifest)
    events = promote_to_ready(preparation, task, actor, attrs)
    task = Repo.get!(Task, task.id)

    %{
      preparation: preparation,
      budget: budget,
      task: task,
      events: events,
      idempotent?: false
    }
  end

  defp create_budget(preparation, task, manifest) do
    budgets = manifest["budgets"]

    %Budget{}
    |> Budget.changeset(%{
      id: Sxf.Identifiers.generate(),
      task_id: task.id,
      status: "active",
      idempotency_key: "preparation:#{preparation.id}:budget",
      max_cost_microusd: budgets["maxCostMicrousd"],
      max_runtime_ms: budgets["maxRuntimeMinutes"] * 60_000,
      max_agent_turns: budgets["maxAgentTurns"],
      max_repair_cycles: budgets["maxRepairCycles"],
      max_provider_retries: @m3_max_provider_retries,
      metadata: %{
        "preparation_id" => preparation.id,
        "registration_fingerprint" => preparation.registration_fingerprint
      }
    })
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  defp promote_to_ready(preparation, task, actor, attrs) do
    {events, _task} =
      Enum.map_reduce(
        [
          {"SPECIFIED", "manifest-gated task contract specified"},
          {"PLANNED", "deterministic M3 execution plan fixed"},
          {"READY", "manifest-gated task is ready for durable dispatch"}
        ],
        task,
        fn {state, reason}, current_task ->
          case StateMachine.validate(current_task.state, state, %{}) do
            :ok -> :ok
            {:error, transition_error} -> Repo.rollback(transition_error)
          end

          event_id = Sxf.Identifiers.generate()
          sequence = current_task.transition_sequence + 1
          idempotency_key = "preparation:#{preparation.id}:#{String.downcase(state)}"

          metadata = %{
            "preparation_id" => preparation.id,
            "semantic_fingerprint" => preparation.semantic_fingerprint
          }

          event_attrs = %{
            id: event_id,
            task_id: current_task.id,
            sequence: sequence,
            actor_id: actor.id,
            prior_state: current_task.state,
            resulting_state: state,
            reason: reason,
            reason_code: "manifest_gated_preparation",
            occurred_at: attrs.prepared_at,
            correlation_id: attrs.correlation_id,
            idempotency_key: idempotency_key,
            request_fingerprint:
              preparation_transition_fingerprint(
                event_id,
                state,
                actor.id,
                reason,
                attrs,
                idempotency_key,
                metadata
              ),
            metadata: metadata
          }

          event =
            %TransitionEvent{}
            |> TransitionEvent.changeset(event_attrs)
            |> Repo.insert()
            |> unwrap_or_rollback()

          updated_task =
            current_task
            |> Task.transition_changeset(%{
              state: state,
              resume_state: nil,
              terminal_at: nil,
              last_transition_at: attrs.prepared_at,
              transition_sequence: sequence
            })
            |> Repo.update()
            |> unwrap_or_rollback()

          {event, updated_task}
        end
      )

    events
  end

  defp preparation_result(preparation, idempotent?) do
    task = Repo.get(Task, preparation.task_id)

    budget =
      Repo.get_by(Budget,
        task_id: preparation.task_id,
        idempotency_key: "preparation:#{preparation.id}:budget"
      )

    events =
      Repo.all(
        from event in TransitionEvent,
          where:
            event.task_id == ^preparation.task_id and
              event.idempotency_key in ^preparation_event_keys(preparation.id),
          order_by: event.sequence
      )

    cond do
      is_nil(task) ->
        {:error, :task_not_found}

      is_nil(budget) ->
        {:error, :preparation_budget_not_found}

      length(events) != 3 ->
        {:error, :preparation_events_incomplete}

      true ->
        {:ok,
         %{
           preparation: preparation,
           budget: budget,
           task: task,
           events: events,
           idempotent?: idempotent?
         }}
    end
  end

  defp latest_source_observation(task, registration) do
    source =
      Repo.one(
        from inbox in ExternalEventInboxReference,
          where: inbox.task_id == ^task.id and inbox.status == "processed",
          order_by: [
            desc: inbox.processed_at,
            desc: inbox.received_at,
            desc: inbox.inserted_at,
            desc: inbox.id
          ],
          limit: 1
      ) || Repo.rollback(:source_observation_not_found)

    metadata = source.metadata

    cond do
      source.source != registration.provider ->
        Repo.rollback(:source_repository_mismatch)

      metadata["repository_external_id"] != registration.external_id ->
        Repo.rollback(:source_repository_mismatch)

      metadata["issue_external_id"] != task.source_ref ->
        Repo.rollback(:source_issue_mismatch)

      not valid_string?(metadata["title"]) ->
        Repo.rollback(:source_observation_incomplete)

      not is_binary(metadata["body"]) or not String.valid?(metadata["body"]) ->
        Repo.rollback(:source_observation_incomplete)

      not is_map(metadata["attributes"]) ->
        Repo.rollback(:source_observation_incomplete)

      true ->
        source
    end
  end

  defp validate_registration_ownership(task, registration) do
    if registration.project_id != task.project_id do
      Repo.rollback(:repository_project_mismatch)
    end
  end

  defp validate_manifest_registration(registration) do
    manifest = registration.normalized_manifest

    cond do
      is_nil(registration.manifest_schema_version) ->
        Repo.rollback(:registration_incomplete)

      registration.manifest_schema_version != "0.1" ->
        Repo.rollback(:unsupported_manifest_version)

      not valid_sha256?(registration.registration_fingerprint) ->
        Repo.rollback(:registration_incomplete)

      not valid_sha256?(registration.raw_manifest_sha256) ->
        Repo.rollback(:registration_incomplete)

      not is_map(manifest) ->
        Repo.rollback(:registration_incomplete)

      manifest["schemaVersion"] != "0.1" ->
        Repo.rollback(:registration_incomplete)

      true ->
        validate_manifest_authority(manifest)
    end
  end

  defp validate_manifest_authority(manifest) do
    commands = manifest["commands"]
    autonomy = manifest["autonomy"]
    verification = manifest["verification"]
    budgets = manifest["budgets"]
    restrictions = manifest["restrictions"]

    cond do
      not is_map(commands) or not valid_string?(commands["install"]) or
          not valid_string?(commands["test"]) ->
        Repo.rollback(:manifest_commands_incomplete)

      not is_map(autonomy) or autonomy["createBranches"] != true ->
        Repo.rollback(:branch_creation_not_authorized)

      autonomy["openPullRequests"] != true ->
        Repo.rollback(:pull_request_creation_not_authorized)

      not is_map(verification) or verification["independent"] != true or
          verification["requireDeterministicChecks"] != true ->
        Repo.rollback(:manifest_verification_incomplete)

      not is_map(restrictions) ->
        Repo.rollback(:manifest_restrictions_incomplete)

      not valid_m3_budgets?(budgets) ->
        Repo.rollback(:manifest_budget_outside_m3_ceiling)

      true ->
        manifest
    end
  end

  defp valid_m3_budgets?(budgets) when is_map(budgets) do
    cost = budgets["maxCostMicrousd"]
    runtime = budgets["maxRuntimeMinutes"]
    turns = budgets["maxAgentTurns"]
    repairs = budgets["maxRepairCycles"]

    is_integer(cost) and cost > 0 and cost <= @m3_max_cost_microusd and
      is_integer(runtime) and runtime > 0 and runtime <= @m3_max_runtime_minutes and
      is_integer(turns) and turns > 0 and turns <= @m3_max_agent_turns and
      is_integer(repairs) and repairs >= 0 and repairs <= @m3_max_repair_cycles
  end

  defp valid_m3_budgets?(_budgets), do: false

  defp build_contract(task, registration, source, manifest) do
    %{
      "version" => "0.1",
      "task" => %{
        "id" => task.id,
        "title" => source.metadata["title"],
        "body" => source.metadata["body"],
        "source" => %{
          "provider" => source.source,
          "repositoryExternalId" => registration.external_id,
          "issueExternalId" => task.source_ref,
          "sourceVersion" => source.source_version,
          "payloadSha256" => source.payload_sha256,
          "attributes" => source.metadata["attributes"]
        }
      },
      "repository" => %{
        "registrationId" => registration.id,
        "provider" => registration.provider,
        "externalId" => registration.external_id,
        "owner" => registration.owner,
        "name" => registration.name,
        "cloneUrl" => registration.clone_url,
        "defaultBranch" => registration.default_branch
      },
      "commands" => manifest["commands"],
      "autonomy" => manifest["autonomy"],
      "verification" => manifest["verification"],
      "restrictions" => manifest["restrictions"],
      "budgets" => %{
        "maxCostMicrousd" => manifest["budgets"]["maxCostMicrousd"],
        "maxRuntimeMs" => manifest["budgets"]["maxRuntimeMinutes"] * 60_000,
        "maxAgentTurns" => manifest["budgets"]["maxAgentTurns"],
        "maxRepairCycles" => manifest["budgets"]["maxRepairCycles"],
        "maxProviderRetries" => @m3_max_provider_retries
      }
    }
  end

  defp semantic_fingerprint(task, registration, source, actor, contract) do
    fingerprint(%{
      command: :prepare_task,
      task_id: task.id,
      project_id: task.project_id,
      repository_registration_id: registration.id,
      registration_fingerprint: registration.registration_fingerprint,
      source_inbox_id: source.id,
      source_version: source.source_version,
      source_payload_sha256: source.payload_sha256,
      actor_id: actor.id,
      contract: contract
    })
  end

  defp preparation_transition_fingerprint(
         event_id,
         resulting_state,
         actor_id,
         reason,
         attrs,
         idempotency_key,
         metadata
       ) do
    fingerprint(%{
      command: :transition_task,
      event_id: event_id,
      resulting_state: resulting_state,
      blocker_id: nil,
      blocker_kind: nil,
      blocker_metadata: %{},
      actor_id: actor_id,
      attempt_id: nil,
      human_decision_id: nil,
      reason: reason,
      reason_code: "manifest_gated_preparation",
      occurred_at: attrs.prepared_at,
      correlation_id: attrs.correlation_id,
      idempotency_key: idempotency_key,
      evidence_reference_ids: [],
      metadata: metadata
    })
  end

  defp preparation_event_keys(preparation_id) do
    for state <- ~w(specified planned ready), do: "preparation:#{preparation_id}:#{state}"
  end

  defp require_fields(attrs, fields) when is_map(attrs) do
    case Enum.find(fields, &(not Map.has_key?(attrs, &1) or is_nil(Map.get(attrs, &1)))) do
      nil -> :ok
      field -> {:error, {:missing_command_field, field}}
    end
  end

  defp require_fields(_attrs, _fields), do: {:error, :invalid_command}

  defp validate_command(attrs) do
    cond do
      not Sxf.Identifiers.valid?(attrs.task_id) ->
        {:error, {:invalid_command_field, :task_id}}

      not Sxf.Identifiers.valid?(attrs.actor_id) ->
        {:error, {:invalid_command_field, :actor_id}}

      not is_struct(attrs.prepared_at, DateTime) ->
        {:error, {:invalid_command_field, :prepared_at}}

      not Sxf.Identifiers.valid?(attrs.correlation_id) ->
        {:error, {:invalid_command_field, :correlation_id}}

      not is_binary(attrs.idempotency_key) or String.trim(attrs.idempotency_key) == "" or
          byte_size(attrs.idempotency_key) > 200 ->
        {:error, {:invalid_command_field, :idempotency_key}}

      true ->
        :ok
    end
  end

  defp valid_string?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_sha256?(value) do
    is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  end

  defp database_locked?(exception) do
    exception
    |> Exception.message()
    |> String.contains?("database is locked")
  end

  defp fingerprint(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp flatten_transaction({:ok, result}), do: {:ok, result}
  defp flatten_transaction({:error, reason}), do: {:error, reason}
end

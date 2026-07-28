defmodule Sxf.ProjectRegistry do
  @moduledoc """
  Durable, provider-neutral connected-project registration.

  Registration validates repository-supplied manifest content through `Sxf.ProjectManifest` and
  persists only its normalized, platform-policy-bounded representation. It performs no network
  access, repository mutation, command execution, or task creation.
  """

  alias Sxf.ProjectManifest
  alias Sxf.Repo
  alias Sxf.Tasks.Actor
  alias Sxf.Tasks.Project
  alias Sxf.Tasks.RepositoryRegistration

  @required_fields [
    :provider,
    :external_id,
    :owner,
    :name,
    :clone_url,
    :default_branch,
    :manifest_content,
    :manifest_format,
    :platform_policy,
    :actor_id,
    :registered_at,
    :correlation_id
  ]

  @doc """
  Validates a manifest and atomically creates or replays one durable repository registration.
  """
  def register_repository(attrs) do
    try do
      with :ok <- require_fields(attrs, @required_fields),
           :ok <- validate_command(attrs),
           {:ok, manifest} <-
             ProjectManifest.load_string(attrs.manifest_content, attrs.manifest_format,
               platform_policy: attrs.platform_policy
             ) do
        snapshot = manifest_snapshot(manifest)
        raw_sha256 = sha256(attrs.manifest_content)
        registration_fingerprint = registration_fingerprint(attrs, snapshot)

        Repo.transaction(fn ->
          register_in_transaction(attrs, snapshot, raw_sha256, registration_fingerprint)
        end)
        |> flatten_transaction()
      end
    rescue
      exception in [DBConnection.ConnectionError, Ecto.ConstraintError, Exqlite.Error] ->
        {:error, {:database_error, Exception.message(exception)}}
    end
  end

  @doc """
  Looks up one durable registration and its normalized manifest by provider-stable identity.
  """
  def lookup_repository(provider, external_id) do
    with :ok <- validate_identity(provider, external_id) do
      case Repo.get_by(RepositoryRegistration, provider: provider, external_id: external_id) do
        nil ->
          {:error, :registration_not_found}

        registration ->
          registration_result(registration, false)
      end
    end
  end

  defp register_in_transaction(attrs, snapshot, raw_sha256, registration_fingerprint) do
    Repo.get(Actor, attrs.actor_id) || Repo.rollback(:actor_not_found)

    case Repo.get_by(RepositoryRegistration,
           provider: attrs.provider,
           external_id: attrs.external_id
         ) do
      %RepositoryRegistration{registration_fingerprint: ^registration_fingerprint} =
          registration ->
        registration
        |> registration_result(true)
        |> unwrap_or_rollback()

      %RepositoryRegistration{} ->
        Repo.rollback(:registration_conflict)

      nil ->
        create_registration(
          attrs,
          snapshot,
          raw_sha256,
          registration_fingerprint
        )
    end
  end

  defp create_registration(attrs, snapshot, raw_sha256, registration_fingerprint) do
    project =
      %Project{}
      |> Project.changeset(%{
        id: Sxf.Identifiers.generate(),
        name: get_in(snapshot, ["project", "name"]),
        status: "active"
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    registration =
      %RepositoryRegistration{}
      |> RepositoryRegistration.registration_changeset(%{
        id: Sxf.Identifiers.generate(),
        project_id: project.id,
        provider: attrs.provider,
        external_id: attrs.external_id,
        owner: attrs.owner,
        name: attrs.name,
        clone_url: attrs.clone_url,
        default_branch: attrs.default_branch,
        manifest_schema_version: snapshot["schemaVersion"],
        normalized_manifest: snapshot,
        raw_manifest_sha256: raw_sha256,
        registration_fingerprint: registration_fingerprint,
        registered_by_actor_id: attrs.actor_id,
        registered_at: attrs.registered_at,
        registration_correlation_id: attrs.correlation_id
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    registration
    |> registration_result(false, project)
    |> unwrap_or_rollback()
  end

  defp registration_result(registration, idempotent?, project \\ nil) do
    project = project || Repo.get(Project, registration.project_id)

    cond do
      is_nil(project) ->
        {:error, :project_not_found}

      is_nil(registration.normalized_manifest) ->
        {:error, :registration_incomplete}

      true ->
        {:ok,
         %{
           project: project,
           repository: registration,
           manifest: registration.normalized_manifest,
           idempotent?: idempotent?
         }}
    end
  end

  defp manifest_snapshot(%ProjectManifest{} = manifest) do
    %{
      "schemaVersion" => manifest.schema_version,
      "project" => manifest.project,
      "commands" => manifest.commands,
      "requestedAutonomy" => manifest.requested_autonomy,
      "autonomy" => manifest.autonomy,
      "verification" => manifest.verification,
      "budgets" => manifest.budgets,
      "restrictions" => manifest.restrictions
    }
  end

  defp registration_fingerprint(attrs, snapshot) do
    fingerprint(%{
      command: :register_repository,
      provider: attrs.provider,
      external_id: attrs.external_id,
      owner: attrs.owner,
      name: attrs.name,
      clone_url: attrs.clone_url,
      default_branch: attrs.default_branch,
      normalized_manifest: snapshot,
      actor_id: attrs.actor_id
    })
  end

  defp validate_command(attrs) do
    with :ok <- validate_identity(attrs.provider, attrs.external_id) do
      cond do
        not valid_string?(attrs.owner, 255) ->
          {:error, {:invalid_command_field, :owner}}

        not valid_string?(attrs.name, 255) ->
          {:error, {:invalid_command_field, :name}}

        not valid_string?(attrs.clone_url, 2048) ->
          {:error, {:invalid_command_field, :clone_url}}

        not valid_string?(attrs.default_branch, 255) ->
          {:error, {:invalid_command_field, :default_branch}}

        not is_binary(attrs.manifest_content) or not String.valid?(attrs.manifest_content) ->
          {:error, {:invalid_command_field, :manifest_content}}

        not Sxf.Identifiers.valid?(attrs.actor_id) ->
          {:error, {:invalid_command_field, :actor_id}}

        not is_struct(attrs.registered_at, DateTime) ->
          {:error, {:invalid_command_field, :registered_at}}

        not Sxf.Identifiers.valid?(attrs.correlation_id) ->
          {:error, {:invalid_command_field, :correlation_id}}

        true ->
          :ok
      end
    end
  end

  defp validate_identity(provider, external_id) do
    cond do
      not valid_string?(provider, 100) ->
        {:error, {:invalid_command_field, :provider}}

      not valid_string?(external_id, 255) ->
        {:error, {:invalid_command_field, :external_id}}

      true ->
        :ok
    end
  end

  defp valid_string?(value, max_bytes) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      byte_size(value) <= max_bytes
  end

  defp require_fields(attrs, fields) when is_map(attrs) do
    case Enum.find(fields, &(not Map.has_key?(attrs, &1) or is_nil(Map.get(attrs, &1)))) do
      nil -> :ok
      field -> {:error, {:missing_command_field, field}}
    end
  end

  defp require_fields(_attrs, _fields), do: {:error, :invalid_command}

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> sha256()
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp flatten_transaction({:ok, result}), do: {:ok, result}
  defp flatten_transaction({:error, reason}), do: {:error, reason}
end

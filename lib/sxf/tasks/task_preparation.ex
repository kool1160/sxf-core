defmodule Sxf.Tasks.TaskPreparation do
  @moduledoc "The immutable manifest-gated contract that authorizes one task to become READY."
  use Sxf.Schema

  schema "task_preparations" do
    field :manifest_schema_version, :string
    field :registration_fingerprint, :string
    field :source_version, :string
    field :source_payload_sha256, :string
    field :contract, :map
    field :semantic_fingerprint, :string
    field :prepared_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    belongs_to :project, Sxf.Tasks.Project
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :repository_registration, Sxf.Tasks.RepositoryRegistration
    belongs_to :source_inbox, Sxf.Tasks.ExternalEventInboxReference
    belongs_to :prepared_by_actor, Sxf.Tasks.Actor
    timestamps(updated_at: false)
  end

  def changeset(preparation, attrs) do
    preparation
    |> cast(attrs, [
      :id,
      :project_id,
      :task_id,
      :repository_registration_id,
      :source_inbox_id,
      :prepared_by_actor_id,
      :manifest_schema_version,
      :registration_fingerprint,
      :source_version,
      :source_payload_sha256,
      :contract,
      :semantic_fingerprint,
      :prepared_at,
      :correlation_id,
      :idempotency_key
    ])
    |> validate_required([
      :project_id,
      :task_id,
      :repository_registration_id,
      :source_inbox_id,
      :prepared_by_actor_id,
      :manifest_schema_version,
      :registration_fingerprint,
      :source_version,
      :source_payload_sha256,
      :contract,
      :semantic_fingerprint,
      :prepared_at,
      :correlation_id,
      :idempotency_key
    ])
    |> validate_inclusion(:manifest_schema_version, ["0.1"])
    |> validate_format(:registration_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:source_payload_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:semantic_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:idempotency_key, min: 1, max: 200)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:repository_registration_id)
    |> foreign_key_constraint(:source_inbox_id)
    |> foreign_key_constraint(:prepared_by_actor_id)
    |> unique_constraint(:task_id)
    |> unique_constraint(:source_inbox_id)
  end
end

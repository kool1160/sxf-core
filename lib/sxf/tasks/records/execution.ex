defmodule Sxf.Tasks.ExecutionEvent do
  @moduledoc "An append-only, fenced event emitted by an execution backend."
  use Sxf.Schema

  @kinds ~w(started progress usage completed failed timed_out cancelled backend_unavailable)

  schema "execution_events" do
    field :sequence, :integer
    field :fencing_token, :integer
    field :kind, :string
    field :occurred_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :payload, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    belongs_to :lease, Sxf.Tasks.WorkerLease
    belongs_to :actor, Sxf.Tasks.Actor
    timestamps(updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :lease_id,
      :actor_id,
      :sequence,
      :fencing_token,
      :kind,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint,
      :payload
    ])
    |> validate_required([
      :task_id,
      :attempt_id,
      :lease_id,
      :actor_id,
      :sequence,
      :fencing_token,
      :kind,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:fencing_token, greater_than: 0)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:lease_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint([:attempt_id, :sequence])
    |> unique_constraint([:task_id, :idempotency_key])
  end
end

defmodule Sxf.Tasks.LeaseRenewal do
  @moduledoc "An append-only idempotency record for a lease extension."
  use Sxf.Schema

  schema "lease_renewals" do
    field :fencing_token, :integer
    field :sequence, :integer
    field :renewed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :idempotency_key, :string
    field :request_fingerprint, :string
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    belongs_to :lease, Sxf.Tasks.WorkerLease
    timestamps(updated_at: false)
  end

  def changeset(renewal, attrs) do
    renewal
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :lease_id,
      :fencing_token,
      :sequence,
      :renewed_at,
      :expires_at,
      :idempotency_key,
      :request_fingerprint
    ])
    |> validate_required([
      :task_id,
      :attempt_id,
      :lease_id,
      :fencing_token,
      :sequence,
      :renewed_at,
      :expires_at,
      :idempotency_key,
      :request_fingerprint
    ])
    |> validate_number(:fencing_token, greater_than: 0)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:lease_id)
    |> unique_constraint([:lease_id, :idempotency_key])
    |> unique_constraint([:lease_id, :sequence])
  end
end

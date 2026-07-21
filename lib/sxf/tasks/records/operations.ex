defmodule Sxf.Tasks.EvidenceReference do
  @moduledoc "Immutable metadata pointing to finalized evidence bytes."
  use Sxf.Schema

  schema "evidence_references" do
    field :kind, :string
    field :storage_uri, :string
    field :sha256, :string
    field :media_type, :string
    field :byte_size, :integer
    field :finalized_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    belongs_to :producer_actor, Sxf.Tasks.Actor
    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :producer_actor_id,
      :kind,
      :storage_uri,
      :sha256,
      :media_type,
      :byte_size,
      :finalized_at,
      :metadata
    ])
    |> validate_required([:task_id, :producer_actor_id, :kind, :storage_uri, :sha256])
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:producer_actor_id)
    |> unique_constraint([:storage_uri, :sha256])
  end
end

defmodule Sxf.Tasks.EventEvidenceReference do
  @moduledoc false
  use Sxf.Schema

  @primary_key false
  schema "event_evidence_references" do
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :transition_event, Sxf.Tasks.TransitionEvent, primary_key: true
    belongs_to :evidence_reference, Sxf.Tasks.EvidenceReference, primary_key: true
    field :attached_at, :utc_datetime_usec
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [:task_id, :transition_event_id, :evidence_reference_id, :attached_at])
    |> validate_required([:task_id, :transition_event_id, :evidence_reference_id, :attached_at])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:transition_event_id)
    |> foreign_key_constraint(:evidence_reference_id)
    |> unique_constraint([:transition_event_id, :evidence_reference_id])
  end
end

defmodule Sxf.Tasks.Budget do
  @moduledoc "Durable task or attempt limits. Quantities use integers for exact accounting."
  use Sxf.Schema

  @statuses ~w(active exhausted closed)

  schema "budgets" do
    field :status, :string, default: "active"
    field :idempotency_key, :string
    field :max_cost_microusd, :integer
    field :max_runtime_ms, :integer
    field :max_agent_turns, :integer
    field :max_repair_cycles, :integer
    field :max_provider_retries, :integer
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    timestamps()
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :status,
      :idempotency_key,
      :max_cost_microusd,
      :max_runtime_ms,
      :max_agent_turns,
      :max_repair_cycles,
      :max_provider_retries,
      :metadata
    ])
    |> validate_required([:task_id, :status, :idempotency_key])
    |> validate_inclusion(:status, @statuses)
    |> validate_limits()
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> unique_constraint([:task_id, :idempotency_key])
  end

  defp validate_limits(changeset) do
    fields =
      ~w(max_cost_microusd max_runtime_ms max_agent_turns max_repair_cycles max_provider_retries)a

    changeset =
      Enum.reduce(fields, changeset, &validate_number(&2, &1, greater_than_or_equal_to: 0))

    if Enum.any?(fields, &get_field(changeset, &1)) do
      changeset
    else
      add_error(changeset, :base, "at least one finite limit is required")
    end
  end
end

defmodule Sxf.Tasks.UsageEntry do
  @moduledoc "An append-only increment against a durable budget."
  use Sxf.Schema

  @metrics ~w(cost_microusd runtime_ms agent_turns repair_cycles provider_retries)

  schema "usage_entries" do
    field :metric, :string
    field :quantity, :integer
    field :occurred_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :metadata, :map, default: %{}
    belongs_to :budget, Sxf.Tasks.Budget
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    belongs_to :actor, Sxf.Tasks.Actor
    timestamps(updated_at: false)
  end

  def metrics, do: @metrics

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :id,
      :budget_id,
      :task_id,
      :attempt_id,
      :actor_id,
      :metric,
      :quantity,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint,
      :metadata
    ])
    |> validate_required([
      :budget_id,
      :task_id,
      :actor_id,
      :metric,
      :quantity,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint
    ])
    |> validate_inclusion(:metric, @metrics)
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:budget_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint([:budget_id, :idempotency_key])
  end
end

defmodule Sxf.Tasks.RetrySchedule do
  @moduledoc "A wall-clock retry entry that survives scheduler restarts."
  use Sxf.Schema

  @statuses ~w(scheduled claimed fired cancelled exhausted)

  schema "retry_schedules" do
    field :sequence, :integer
    field :status, :string, default: "scheduled"
    field :due_at, :utc_datetime_usec
    field :reason, :string
    field :resume_state, :string
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :claimed_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    timestamps()
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :sequence,
      :status,
      :due_at,
      :reason,
      :resume_state,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint,
      :claimed_at,
      :finished_at,
      :metadata
    ])
    |> validate_required([
      :task_id,
      :sequence,
      :status,
      :due_at,
      :reason,
      :resume_state,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:resume_state, Sxf.Tasks.StateMachine.nonterminal_states())
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> unique_constraint([:task_id, :sequence])
    |> unique_constraint([:task_id, :idempotency_key])
  end
end

defmodule Sxf.Tasks.WorkerLease do
  @moduledoc "A fenced worker claim whose expiry can be reconciled deterministically."
  use Sxf.Schema

  @statuses ~w(active released expired lost)

  schema "worker_leases" do
    field :worker_id, :string
    field :fencing_token, :integer
    field :status, :string, default: "active"
    field :acquired_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    timestamps()
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :worker_id,
      :fencing_token,
      :status,
      :acquired_at,
      :heartbeat_at,
      :expires_at,
      :released_at,
      :idempotency_key,
      :request_fingerprint,
      :metadata
    ])
    |> validate_required([
      :task_id,
      :attempt_id,
      :worker_id,
      :fencing_token,
      :status,
      :acquired_at,
      :heartbeat_at,
      :expires_at,
      :idempotency_key
    ])
    |> validate_number(:fencing_token, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_expiry_order()
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> unique_constraint([:task_id, :fencing_token])
    |> unique_constraint([:task_id, :idempotency_key])
  end

  defp validate_expiry_order(changeset) do
    acquired_at = get_field(changeset, :acquired_at)
    expires_at = get_field(changeset, :expires_at)

    if acquired_at && expires_at && DateTime.compare(expires_at, acquired_at) != :gt do
      add_error(changeset, :expires_at, "must be after acquired_at")
    else
      changeset
    end
  end
end

defmodule Sxf.Tasks.Blocker do
  @moduledoc "A durable reason that prevents a task from progressing."
  use Sxf.Schema

  @kinds ~w(dependency policy approval_required budget_exhausted runtime_exhausted worker_lost lease_expired indeterminate_outcome external_failure operator_input)
  @statuses ~w(active resolved)

  schema "blockers" do
    field :kind, :string
    field :status, :string, default: "active"
    field :reason, :string
    field :resume_state, :string
    field :created_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :resolution_idempotency_key, :string
    field :resolution_correlation_id, Ecto.UUID
    field :resolution_request_fingerprint, :string
    field :correlation_id, Ecto.UUID
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    belongs_to :created_by_actor, Sxf.Tasks.Actor
    belongs_to :resolved_by_actor, Sxf.Tasks.Actor
    belongs_to :resolution_human_decision, Sxf.Tasks.HumanDecision
    timestamps()
  end

  def kinds, do: @kinds

  def changeset(blocker, attrs) do
    blocker
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :created_by_actor_id,
      :resolved_by_actor_id,
      :kind,
      :status,
      :reason,
      :resume_state,
      :created_at,
      :resolved_at,
      :resolution_idempotency_key,
      :resolution_correlation_id,
      :resolution_human_decision_id,
      :resolution_request_fingerprint,
      :correlation_id,
      :metadata
    ])
    |> validate_required([
      :task_id,
      :created_by_actor_id,
      :kind,
      :status,
      :reason,
      :resume_state,
      :created_at,
      :correlation_id
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:resume_state, Sxf.Tasks.StateMachine.nonterminal_states())
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:created_by_actor_id)
    |> foreign_key_constraint(:resolved_by_actor_id)
    |> foreign_key_constraint(:resolution_human_decision_id)
    |> validate_format(:resolution_request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:resolution_human_decision_id)
  end
end

defmodule Sxf.Tasks.HumanDecision do
  @moduledoc "An explicit human approval, rejection, unblock, cancellation, or reopen decision."
  use Sxf.Schema

  @kinds ~w(approval rejection unblock cancel reopen deploy_approval budget_override)
  @decisions ~w(approved rejected)

  schema "human_decisions" do
    field :kind, :string
    field :decision, :string
    field :reason, :string
    field :occurred_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    field :target_type, :string
    field :target_id, Ecto.UUID
    field :target_action, :string
    field :request_fingerprint, :string
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :actor, Sxf.Tasks.Actor
    belongs_to :evidence_reference, Sxf.Tasks.EvidenceReference
    timestamps(updated_at: false)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :id,
      :task_id,
      :actor_id,
      :evidence_reference_id,
      :kind,
      :decision,
      :reason,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :target_type,
      :target_id,
      :target_action,
      :request_fingerprint,
      :metadata
    ])
    |> validate_required([
      :task_id,
      :actor_id,
      :kind,
      :decision,
      :reason,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :target_type,
      :target_id,
      :target_action,
      :request_fingerprint
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:decision, @decisions)
    |> validate_inclusion(:target_type, ~w(transition blocker_resolution))
    |> validate_length(:target_action, min: 1)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:evidence_reference_id)
    |> unique_constraint([:task_id, :idempotency_key])
  end
end

defmodule Sxf.Tasks.ExternalEventInboxReference do
  @moduledoc "Idempotency metadata for a future external-event inbox processor."
  use Sxf.Schema

  schema "external_event_inbox_references" do
    field :source, :string
    field :external_id, :string
    field :payload_sha256, :string
    field :status, :string, default: "received"
    field :received_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    timestamps()
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [
      :id,
      :task_id,
      :source,
      :external_id,
      :payload_sha256,
      :status,
      :received_at,
      :processed_at,
      :correlation_id,
      :metadata
    ])
    |> validate_required([
      :source,
      :external_id,
      :payload_sha256,
      :status,
      :received_at,
      :correlation_id
    ])
    |> validate_inclusion(:status, ~w(received processed rejected))
    |> validate_format(:payload_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:source, :external_id])
  end
end

defmodule Sxf.Tasks.ExternalActionOutboxReference do
  @moduledoc "Durable intent metadata for a future external-action dispatcher."
  use Sxf.Schema

  schema "external_action_outbox_references" do
    field :destination, :string
    field :action, :string
    field :payload_sha256, :string
    field :status, :string, default: "pending"
    field :available_at, :utc_datetime_usec
    field :attempted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    timestamps()
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [
      :id,
      :task_id,
      :attempt_id,
      :destination,
      :action,
      :payload_sha256,
      :status,
      :available_at,
      :attempted_at,
      :completed_at,
      :correlation_id,
      :idempotency_key,
      :metadata
    ])
    |> validate_required([
      :task_id,
      :destination,
      :action,
      :payload_sha256,
      :status,
      :available_at,
      :correlation_id,
      :idempotency_key
    ])
    |> validate_inclusion(:status, ~w(pending dispatching succeeded failed unknown))
    |> validate_format(:payload_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> unique_constraint([:destination, :idempotency_key])
  end
end

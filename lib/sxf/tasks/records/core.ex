defmodule Sxf.Tasks.Project do
  @moduledoc "A durable SXF project identity."
  use Sxf.Schema

  schema "projects" do
    field :name, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}
    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:id, :name, :status, :metadata])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, ~w(active archived))
  end
end

defmodule Sxf.Tasks.RepositoryRegistration do
  @moduledoc "A provider-neutral registration of a source repository."
  use Sxf.Schema

  schema "repository_registrations" do
    field :provider, :string
    field :external_id, :string
    field :owner, :string
    field :name, :string
    field :clone_url, :string
    field :default_branch, :string, default: "main"
    field :metadata, :map, default: %{}
    belongs_to :project, Sxf.Tasks.Project
    timestamps()
  end

  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :id,
      :project_id,
      :provider,
      :external_id,
      :owner,
      :name,
      :clone_url,
      :default_branch,
      :metadata
    ])
    |> validate_required([:project_id, :provider, :external_id, :owner, :name, :clone_url])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:provider, :external_id])
  end
end

defmodule Sxf.Tasks.Actor do
  @moduledoc "The durable identity responsible for a domain command or observation."
  use Sxf.Schema

  @kinds ~w(system human worker agent_backend external_system)

  schema "actors" do
    field :kind, :string
    field :external_ref, :string
    field :display_name, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  def kinds, do: @kinds

  def changeset(actor, attrs) do
    actor
    |> cast(attrs, [:id, :kind, :external_ref, :display_name, :metadata])
    |> validate_required([:kind, :display_name])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:kind, :external_ref])
  end
end

defmodule Sxf.Tasks.Task do
  @moduledoc "The current projection of an SXF task. Transition events remain authoritative."
  use Sxf.Schema

  schema "tasks" do
    field :title, :string
    field :source_ref, :string
    field :state, :string, default: "DISCOVERED"
    field :resume_state, :string
    field :terminal_at, :utc_datetime_usec
    field :last_transition_at, :utc_datetime_usec
    field :transition_sequence, :integer, default: 1
    field :lock_version, :integer, default: 1
    field :metadata, :map, default: %{}
    belongs_to :project, Sxf.Tasks.Project
    belongs_to :repository_registration, Sxf.Tasks.RepositoryRegistration
    has_many :attempts, Sxf.Tasks.TaskAttempt
    has_many :transition_events, Sxf.Tasks.TransitionEvent
    timestamps()
  end

  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :id,
      :project_id,
      :repository_registration_id,
      :title,
      :source_ref,
      :state,
      :last_transition_at,
      :transition_sequence,
      :metadata
    ])
    |> validate_required([
      :id,
      :project_id,
      :repository_registration_id,
      :title,
      :state,
      :last_transition_at,
      :transition_sequence
    ])
    |> validate_inclusion(:state, Sxf.Tasks.StateMachine.states())
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:repository_registration_id)
  end

  def transition_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :state,
      :resume_state,
      :terminal_at,
      :last_transition_at,
      :transition_sequence
    ])
    |> validate_required([:state, :last_transition_at, :transition_sequence])
    |> validate_number(:transition_sequence, greater_than: 0)
    |> validate_inclusion(:state, Sxf.Tasks.StateMachine.states())
    |> validate_inclusion(:resume_state, Sxf.Tasks.StateMachine.nonterminal_states())
    |> optimistic_lock(:lock_version)
  end
end

defmodule Sxf.Tasks.TaskAttempt do
  @moduledoc "A bounded execution or repair attempt, independent of any agent provider."
  use Sxf.Schema

  @statuses ~w(planned running succeeded failed cancelled unknown lost)

  schema "task_attempts" do
    field :sequence, :integer
    field :status, :string, default: "planned"
    field :backend, :string
    field :backend_session_id, :string
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :outcome, :string
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    timestamps()
  end

  def statuses, do: @statuses

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :id,
      :task_id,
      :sequence,
      :status,
      :backend,
      :backend_session_id,
      :idempotency_key,
      :request_fingerprint,
      :started_at,
      :finished_at,
      :outcome,
      :metadata
    ])
    |> validate_required([:task_id, :sequence, :status, :idempotency_key, :request_fingerprint])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :sequence])
    |> unique_constraint([:task_id, :idempotency_key])
  end
end

defmodule Sxf.Tasks.TransitionEvent do
  @moduledoc "An append-only, attributable task-state fact."
  use Sxf.Schema

  schema "task_transition_events" do
    field :sequence, :integer
    field :prior_state, :string
    field :resulting_state, :string
    field :reason, :string
    field :reason_code, :string
    field :occurred_at, :utc_datetime_usec
    field :correlation_id, Ecto.UUID
    field :idempotency_key, :string
    field :request_fingerprint, :string
    field :metadata, :map, default: %{}
    belongs_to :task, Sxf.Tasks.Task
    belongs_to :attempt, Sxf.Tasks.TaskAttempt
    belongs_to :actor, Sxf.Tasks.Actor
    belongs_to :human_decision, Sxf.Tasks.HumanDecision

    many_to_many :evidence_references, Sxf.Tasks.EvidenceReference,
      join_through: Sxf.Tasks.EventEvidenceReference

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :task_id,
      :sequence,
      :attempt_id,
      :actor_id,
      :prior_state,
      :resulting_state,
      :reason,
      :reason_code,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint,
      :human_decision_id,
      :metadata
    ])
    |> validate_required([
      :task_id,
      :sequence,
      :actor_id,
      :resulting_state,
      :reason,
      :occurred_at,
      :correlation_id,
      :idempotency_key,
      :request_fingerprint
    ])
    |> validate_length(:reason, min: 1)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_inclusion(:prior_state, Sxf.Tasks.StateMachine.states())
    |> validate_inclusion(:resulting_state, Sxf.Tasks.StateMachine.states())
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:human_decision_id)
    |> unique_constraint([:task_id, :idempotency_key])
    |> unique_constraint([:task_id, :sequence])
    |> unique_constraint(:human_decision_id)
  end
end

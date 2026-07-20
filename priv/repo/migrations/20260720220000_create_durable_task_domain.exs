defmodule Sxf.Repo.Migrations.CreateDurableTaskDomain do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create table(:repository_registrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :provider, :string, null: false
      add :external_id, :string, null: false
      add :owner, :string, null: false
      add :name, :string, null: false
      add :clone_url, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_registrations, [:provider, :external_id])
    create unique_index(:repository_registrations, [:id, :project_id])
    create index(:repository_registrations, [:project_id])

    create table(:actors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :external_ref, :string
      add :display_name, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:actors, [:kind, :external_ref])

    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :repository_registration_id,
          references(:repository_registrations,
            type: :binary_id,
            on_delete: :restrict,
            with: [project_id: :project_id]
          ),
          null: false

      add :title, :string, null: false
      add :source_ref, :string
      add :state, :string, null: false
      add :resume_state, :string
      add :terminal_at, :utc_datetime_usec
      add :last_transition_at, :utc_datetime_usec, null: false
      add :transition_sequence, :integer, null: false, default: 1
      add :lock_version, :integer, null: false, default: 1
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:project_id, :state])
    create index(:tasks, [:repository_registration_id, :source_ref])

    create table(:task_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false
      add :sequence, :integer, null: false
      add :status, :string, null: false
      add :backend, :string
      add :backend_session_id, :string
      add :idempotency_key, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :outcome, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_attempts, [:task_id, :sequence])
    create unique_index(:task_attempts, [:task_id, :idempotency_key])
    create unique_index(:task_attempts, [:id, :task_id])

    create table(:evidence_references, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :producer_actor_id, references(:actors, type: :binary_id, on_delete: :restrict),
        null: false

      add :kind, :string, null: false
      add :storage_uri, :string, null: false
      add :sha256, :string, size: 64, null: false
      add :media_type, :string
      add :byte_size, :integer
      add :finalized_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:evidence_references, [:storage_uri, :sha256])
    create unique_index(:evidence_references, [:id, :task_id])
    create index(:evidence_references, [:task_id, :attempt_id])

    create table(:budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :status, :string, null: false
      add :idempotency_key, :string, null: false
      add :max_cost_microusd, :integer
      add :max_runtime_ms, :integer
      add :max_agent_turns, :integer
      add :max_repair_cycles, :integer
      add :max_provider_retries, :integer
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:budgets, [:task_id, :idempotency_key])
    create index(:budgets, [:task_id, :status])

    create table(:worker_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          null: false

      add :worker_id, :string, null: false
      add :fencing_token, :integer, null: false
      add :status, :string, null: false
      add :acquired_at, :utc_datetime_usec, null: false
      add :heartbeat_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      add :idempotency_key, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:worker_leases, [:task_id, :fencing_token])
    create unique_index(:worker_leases, [:task_id, :idempotency_key])
    create index(:worker_leases, [:status, :expires_at])

    create table(:human_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false
      add :actor_id, references(:actors, type: :binary_id, on_delete: :restrict), null: false

      add :evidence_reference_id,
          references(:evidence_references, type: :binary_id, on_delete: :restrict)

      add :kind, :string, null: false
      add :decision, :string, null: false
      add :reason, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :target_action, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:human_decisions, [:task_id, :idempotency_key])

    create table(:blockers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :created_by_actor_id, references(:actors, type: :binary_id, on_delete: :restrict),
        null: false

      add :resolved_by_actor_id, references(:actors, type: :binary_id, on_delete: :restrict)
      add :kind, :string, null: false
      add :status, :string, null: false
      add :reason, :text, null: false
      add :resume_state, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :resolution_idempotency_key, :string
      add :resolution_correlation_id, :binary_id

      add :resolution_human_decision_id,
          references(:human_decisions, type: :binary_id, on_delete: :restrict)

      add :resolution_request_fingerprint, :string, size: 64
      add :correlation_id, :binary_id, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:blockers, [:task_id, :status])
    create unique_index(:blockers, [:task_id, :resolution_idempotency_key])
    create unique_index(:blockers, [:resolution_human_decision_id])

    create table(:retry_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :sequence, :integer, null: false
      add :status, :string, null: false
      add :due_at, :utc_datetime_usec, null: false
      add :reason, :text, null: false
      add :resume_state, :string, null: false
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :claimed_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:retry_schedules, [:task_id, :sequence])
    create unique_index(:retry_schedules, [:task_id, :idempotency_key])
    create index(:retry_schedules, [:status, :due_at])

    create table(:usage_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :budget_id, references(:budgets, type: :binary_id, on_delete: :restrict), null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :actor_id, references(:actors, type: :binary_id, on_delete: :restrict), null: false
      add :metric, :string, null: false
      add :quantity, :integer, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:usage_entries, [:budget_id, :idempotency_key])
    create index(:usage_entries, [:task_id, :attempt_id, :metric])

    create table(:task_transition_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :actor_id, references(:actors, type: :binary_id, on_delete: :restrict), null: false
      add :prior_state, :string
      add :resulting_state, :string, null: false
      add :reason, :text, null: false
      add :reason_code, :string
      add :occurred_at, :utc_datetime_usec, null: false
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :sequence, :integer, null: false

      add :human_decision_id,
          references(:human_decisions, type: :binary_id, on_delete: :restrict)

      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:task_transition_events, [:task_id, :idempotency_key])
    create unique_index(:task_transition_events, [:task_id, :sequence])
    create unique_index(:task_transition_events, [:id, :task_id])
    create unique_index(:task_transition_events, [:human_decision_id])
    create index(:task_transition_events, [:task_id, :occurred_at])

    create table(:event_evidence_references, primary_key: false) do
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :transition_event_id,
          references(:task_transition_events,
            type: :binary_id,
            on_delete: :delete_all,
            with: [task_id: :task_id]
          ),
          primary_key: true

      add :evidence_reference_id,
          references(:evidence_references,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          primary_key: true

      add :attached_at, :utc_datetime_usec, null: false
    end

    create table(:external_event_inbox_references, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict)
      add :source, :string, null: false
      add :external_id, :string, null: false
      add :payload_sha256, :string, size: 64, null: false
      add :status, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :processed_at, :utc_datetime_usec
      add :correlation_id, :binary_id, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:external_event_inbox_references, [:source, :external_id])
    create index(:external_event_inbox_references, [:status, :received_at])

    create table(:external_action_outbox_references, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          )

      add :destination, :string, null: false
      add :action, :string, null: false
      add :payload_sha256, :string, size: 64, null: false
      add :status, :string, null: false
      add :available_at, :utc_datetime_usec, null: false
      add :attempted_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:external_action_outbox_references, [:destination, :idempotency_key])
    create index(:external_action_outbox_references, [:status, :available_at])
  end
end

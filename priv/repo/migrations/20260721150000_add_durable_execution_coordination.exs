defmodule Sxf.Repo.Migrations.AddDurableExecutionCoordination do
  use Ecto.Migration

  def change do
    alter table(:task_attempts) do
      add :execution_event_sequence, :integer, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1
    end

    alter table(:worker_leases) do
      add :request_fingerprint, :string, size: 64
    end

    create unique_index(:worker_leases, [:id, :task_id])

    create table(:execution_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          null: false

      add :lease_id,
          references(:worker_leases,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          null: false

      add :actor_id, references(:actors, type: :binary_id, on_delete: :restrict), null: false
      add :sequence, :integer, null: false
      add :fencing_token, :integer, null: false
      add :kind, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :payload, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:execution_events, [:attempt_id, :sequence])
    create unique_index(:execution_events, [:task_id, :idempotency_key])
    create index(:execution_events, [:task_id, :attempt_id, :occurred_at])

    create table(:lease_renewals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, references(:tasks, type: :binary_id, on_delete: :restrict), null: false

      add :attempt_id,
          references(:task_attempts,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          null: false

      add :lease_id,
          references(:worker_leases,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          null: false

      add :fencing_token, :integer, null: false
      add :renewed_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :idempotency_key, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:lease_renewals, [:lease_id, :idempotency_key])
    create index(:lease_renewals, [:task_id, :attempt_id, :renewed_at])
  end
end

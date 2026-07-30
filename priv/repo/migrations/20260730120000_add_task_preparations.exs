defmodule Sxf.Repo.Migrations.AddTaskPreparations do
  use Ecto.Migration

  def change do
    create unique_index(:tasks, [:id, :project_id])
    create unique_index(:external_event_inbox_references, [:id, :task_id])

    create table(:task_preparations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      add :task_id,
          references(:tasks,
            type: :binary_id,
            on_delete: :restrict,
            with: [project_id: :project_id]
          ),
          null: false

      add :repository_registration_id,
          references(:repository_registrations,
            type: :binary_id,
            on_delete: :restrict,
            with: [project_id: :project_id]
          ),
          null: false

      add :source_inbox_id,
          references(:external_event_inbox_references,
            type: :binary_id,
            on_delete: :restrict,
            with: [task_id: :task_id]
          ),
          null: false

      add :prepared_by_actor_id, references(:actors, type: :binary_id, on_delete: :restrict),
        null: false

      add :manifest_schema_version, :string, null: false
      add :registration_fingerprint, :string, size: 64, null: false
      add :source_version, :string, null: false
      add :source_payload_sha256, :string, size: 64, null: false
      add :contract, :map, null: false
      add :semantic_fingerprint, :string, size: 64, null: false
      add :prepared_at, :utc_datetime_usec, null: false
      add :correlation_id, :binary_id, null: false
      add :idempotency_key, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:task_preparations, [:task_id])
    create unique_index(:task_preparations, [:source_inbox_id])
    create index(:task_preparations, [:project_id])
    create index(:task_preparations, [:repository_registration_id])
    create index(:task_preparations, [:prepared_by_actor_id])
  end
end

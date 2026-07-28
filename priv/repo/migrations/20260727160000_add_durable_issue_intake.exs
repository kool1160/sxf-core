defmodule Sxf.Repo.Migrations.AddDurableIssueIntake do
  use Ecto.Migration

  @legacy_fingerprint String.duplicate("0", 64)

  def up do
    alter table(:external_event_inbox_references) do
      add :source_version, :string, null: false, default: "legacy"
      add :request_fingerprint, :string, size: 64, null: false, default: @legacy_fingerprint
    end

    drop index(:tasks, [:repository_registration_id, :source_ref])

    create unique_index(:tasks, [:repository_registration_id, :source_ref])

    create index(:external_event_inbox_references, [:task_id, :received_at])
  end

  def down do
    drop index(:external_event_inbox_references, [:task_id, :received_at])

    drop index(:tasks, [:repository_registration_id, :source_ref])
    create index(:tasks, [:repository_registration_id, :source_ref])

    alter table(:external_event_inbox_references) do
      remove :source_version
      remove :request_fingerprint
    end
  end
end

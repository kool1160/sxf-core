defmodule Sxf.Repo.Migrations.AddEvidenceByteStoreContract do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:evidence_references, [:storage_uri, :sha256])

    alter table(:evidence_references) do
      add :correlation_id, :binary_id
      add :idempotency_key, :string
      add :request_fingerprint, :string, size: 64
      add :redacted, :boolean, null: false, default: false
    end

    create unique_index(:evidence_references, [:task_id, :idempotency_key])
    create index(:evidence_references, [:sha256])

    execute("""
    CREATE TRIGGER evidence_references_finalized_update_guard
    BEFORE UPDATE ON evidence_references
    WHEN OLD.finalized_at IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'finalized evidence references are immutable');
    END
    """)

    execute("""
    CREATE TRIGGER evidence_references_finalized_delete_guard
    BEFORE DELETE ON evidence_references
    WHEN OLD.finalized_at IS NOT NULL
    BEGIN
      SELECT RAISE(ABORT, 'finalized evidence references are immutable');
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS evidence_references_finalized_delete_guard")
    execute("DROP TRIGGER IF EXISTS evidence_references_finalized_update_guard")

    drop_if_exists index(:evidence_references, [:sha256])
    drop_if_exists unique_index(:evidence_references, [:task_id, :idempotency_key])

    alter table(:evidence_references) do
      remove :redacted
      remove :request_fingerprint
      remove :idempotency_key
      remove :correlation_id
    end

    create unique_index(:evidence_references, [:storage_uri, :sha256])
  end
end

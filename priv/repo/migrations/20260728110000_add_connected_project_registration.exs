defmodule Sxf.Repo.Migrations.AddConnectedProjectRegistration do
  use Ecto.Migration

  def change do
    alter table(:repository_registrations) do
      add :manifest_schema_version, :string
      add :normalized_manifest, :map
      add :raw_manifest_sha256, :string, size: 64
      add :registration_fingerprint, :string, size: 64

      add :registered_by_actor_id,
          references(:actors, type: :binary_id, on_delete: :restrict)

      add :registered_at, :utc_datetime_usec
      add :registration_correlation_id, :binary_id
    end

    create index(:repository_registrations, [:registered_by_actor_id])
  end
end

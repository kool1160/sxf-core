defmodule Sxf.Repo.Migrations.AddAttemptRuntimeDeadline do
  use Ecto.Migration

  def change do
    alter table(:task_attempts) do
      add :runtime_deadline_at, :utc_datetime_usec
    end
  end
end

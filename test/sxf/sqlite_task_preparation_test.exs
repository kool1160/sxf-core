defmodule Sxf.SQLiteTaskPreparationTest do
  use ExUnit.Case, async: false

  @result_prefix "SXF_SQLITE_TASK_PREPARATION_RESULT="

  test "independent SQLite connections create one restart-durable preparation authority" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "sxf-sqlite-task-preparation-#{Ecto.UUID.generate()}"
      )

    database = Path.join(test_root, "preparation.db")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      remove_database_files(database)
      if File.exists?(test_root), do: File.rmdir!(test_root)
    end)

    {output, exit_status} = run_isolated_preparation(database)
    assert exit_status == 0, output

    result =
      output
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, @result_prefix, parts: 2) do
          ["", encoded] ->
            encoded
            |> Base.decode64!()
            |> :erlang.binary_to_term([:safe])

          _ ->
            nil
        end
      end)

    assert %{
             created_count: 1,
             replay_count: 1,
             preparation_count: 1,
             budget_count: 1,
             transition_count: 4,
             task_state: "READY",
             attempt_count: 0,
             lease_count: 0,
             retry_count: 0,
             blocker_count: 0,
             usage_count: 0,
             evidence_count: 0,
             outbox_count: 0,
             restart_lookup?: true,
             restart_task_state: "READY",
             restart_transition_count: 4,
             contention_repo_stopped?: true,
             first_repo_stopped?: true,
             restarted_repo_stopped?: true
           } = result

    assert result.restart_budget_id == result.budget_id

    remove_database_files(database)

    for path <- [database, "#{database}-wal", "#{database}-shm"] do
      refute File.exists?(path)
    end

    assert :ok = File.rmdir(test_root)
  end

  defp run_isolated_preparation(database) do
    script = Path.expand("../support/run_sqlite_task_preparation.exs", __DIR__)

    args = [
      "run",
      "--no-start",
      "--no-compile",
      script,
      "--",
      database
    ]

    options = [
      cd: File.cwd!(),
      env: [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", Mix.Project.build_path()}
      ],
      stderr_to_stdout: true
    ]

    case :os.type() do
      {:win32, _} ->
        command = System.find_executable("cmd.exe") || raise "cmd.exe was not found"
        mix = System.find_executable("mix.bat") || raise "mix.bat was not found"
        System.cmd(command, ["/d", "/c", "call", mix | args], options)

      _ ->
        mix = System.find_executable("mix") || raise "mix was not found"
        System.cmd(mix, args, options)
    end
  end

  defp remove_database_files(database) do
    for path <- [database, "#{database}-wal", "#{database}-shm"] do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
      end
    end
  end
end

defmodule Sxf.GitHub.SQLiteIssuePollerTest do
  use ExUnit.Case, async: false

  @result_prefix "SXF_SQLITE_GITHUB_POLLER_RESULT="

  test "Repo stop and restart followed by polling replays without duplicate work" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "sxf-sqlite-github-poller-#{Ecto.UUID.generate()}"
      )

    database = Path.join(test_root, "github-poller.db")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      remove_database_files(database)
      if File.exists?(test_root), do: File.rmdir!(test_root)
    end)

    {output, exit_status} = run_isolated_poller(database)
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

          _other ->
            nil
        end
      end)

    assert %{
             first_task_count: 1,
             first_inbox_count: 1,
             first_transition_count: 1,
             restart_tasks_created: 0,
             restart_replayed: 1,
             restart_task_state: "DISCOVERED",
             restart_task_count: 1,
             restart_inbox_count: 1,
             restart_transition_count: 1,
             attempt_count: 0,
             lease_count: 0,
             retry_count: 0,
             blocker_count: 0,
             budget_count: 0,
             usage_count: 0,
             outbox_count: 0,
             first_repo_stopped?: true,
             restarted_repo_stopped?: true
           } = result

    remove_database_files(database)

    for path <- [database, "#{database}-wal", "#{database}-shm"] do
      refute File.exists?(path)
    end

    assert :ok = File.rmdir(test_root)
  end

  defp run_isolated_poller(database) do
    script =
      Path.expand(
        "../../support/run_sqlite_github_poller.exs",
        __DIR__
      )

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
        {"MIX_BUILD_PATH", Mix.Project.build_path()},
        {"MIX_DEPS_PATH", Mix.Project.deps_path()}
      ],
      stderr_to_stdout: true
    ]

    case :os.type() do
      {:win32, _} ->
        command = System.find_executable("cmd.exe") || raise "cmd.exe was not found"
        mix = System.find_executable("mix.bat") || raise "mix.bat was not found"
        System.cmd(command, ["/d", "/c", "call", mix | args], options)

      _other ->
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

defmodule Sxf.Tasks.SQLiteIntakeContentionTest do
  use ExUnit.Case, async: false

  @result_prefix "SXF_SQLITE_INTAKE_CONTENTION_RESULT="

  test "independent SQLite connections normalize one inbox and task without duplicates" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "sxf-sqlite-intake-contention-#{Ecto.UUID.generate()}"
      )

    database = Path.join(test_root, "contention.db")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      remove_database_files(database)
      if File.exists?(test_root), do: File.rmdir!(test_root)
    end)

    {output, exit_status} = run_isolated_contention(database)

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
             inbox_count: 1,
             task_count: 1,
             creation_event_count: 1,
             task_state: "DISCOVERED",
             task_transition_sequence: 1,
             inbox_status: "processed",
             repo_stopped?: true
           } = result

    remove_database_files(database)

    for path <- [database, "#{database}-wal", "#{database}-shm"] do
      refute File.exists?(path)
    end

    assert :ok = File.rmdir(test_root)
  end

  defp run_isolated_contention(database) do
    script =
      Path.expand(
        "../../support/run_sqlite_intake_contention.exs",
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

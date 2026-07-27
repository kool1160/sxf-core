defmodule Sxf.Execution.SQLiteClaimContentionTest do
  use ExUnit.Case, async: false

  @result_prefix "SXF_SQLITE_CONTENTION_RESULT="

  test "independent SQLite connections serialize one durable claim without duplicate authority" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "sxf-sqlite-claim-contention-#{Ecto.UUID.generate()}"
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
             claim_count: 1,
             no_work_count: 1,
             running_attempt_count: 1,
             active_lease_count: 1,
             ready_to_implementing_count: 1,
             task_state: "IMPLEMENTING",
             first_attempt_sequence_count: 1,
             first_fencing_token_count: 1,
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
        "../../support/run_sqlite_claim_contention.exs",
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

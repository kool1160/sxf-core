defmodule Sxf.SQLiteEvidenceTest do
  use ExUnit.Case, async: false

  @result_prefix "SXF_SQLITE_EVIDENCE_RESULT="

  test "evidence reference and bytes remain verified after Repo restart" do
    root =
      Path.join(
        System.tmp_dir!(),
        "sxf-sqlite-evidence-#{Ecto.UUID.generate()}"
      )

    database = Path.join(root, "evidence.db")
    evidence_root = Path.join(root, "bytes")
    File.mkdir_p!(root)

    on_exit(fn ->
      remove_database_files(database)
      File.rm_rf!(evidence_root)
      if File.exists?(root), do: File.rmdir!(root)
    end)

    {output, exit_status} = run_isolated(database, evidence_root)
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
             reference_count: 1,
             created_count: 1,
             replay_count: 1,
             one_reference_identity?: true,
             restart_reference_count: 1,
             restart_bytes_equal?: true,
             restart_sha_equal?: true,
             restart_verified?: true,
             first_repo_stopped?: true,
             restarted_repo_stopped?: true
           } = result

    remove_database_files(database)
    File.rm_rf!(evidence_root)

    for path <- [database, "#{database}-wal", "#{database}-shm", evidence_root] do
      refute File.exists?(path)
    end

    assert :ok = File.rmdir(root)
  end

  defp run_isolated(database, evidence_root) do
    script = Path.expand("../support/run_sqlite_evidence.exs", __DIR__)

    args = [
      "run",
      "--no-start",
      "--no-compile",
      script,
      "--",
      database,
      evidence_root
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

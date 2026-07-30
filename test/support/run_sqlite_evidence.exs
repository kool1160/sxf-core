{database, evidence_root} =
  case System.argv() do
    [database, evidence_root] -> {database, evidence_root}
    ["--", database, evidence_root] -> {database, evidence_root}
    arguments -> raise "expected SQLite database and evidence root, got: #{inspect(arguments)}"
  end

{:ok, _started} = Application.ensure_all_started(:ecto_sqlite3)
result = Sxf.SQLiteEvidenceRunner.run!(database, evidence_root)
encoded = result |> :erlang.term_to_binary() |> Base.encode64()
IO.puts("SXF_SQLITE_EVIDENCE_RESULT=#{encoded}")

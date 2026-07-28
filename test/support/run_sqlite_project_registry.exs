database =
  case System.argv() do
    [database] -> database
    ["--", database] -> database
    arguments -> raise "expected one SQLite database path, got: #{inspect(arguments)}"
  end

{:ok, _started} = Application.ensure_all_started(:ecto_sqlite3)
result = Sxf.SQLiteProjectRegistryRunner.run!(database)
encoded = result |> :erlang.term_to_binary() |> Base.encode64()
IO.puts("SXF_SQLITE_PROJECT_REGISTRY_RESULT=#{encoded}")

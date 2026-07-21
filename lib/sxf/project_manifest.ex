defmodule Sxf.ProjectManifest do
  @moduledoc """
  Pure loading, validation, normalization, and policy bounding for connected-project manifests.

  Loading reads one file only. It does not execute declared commands, modify the repository, persist
  onboarding state, or broaden platform permissions.
  """

  alias Sxf.ProjectManifest.Error
  alias Sxf.ProjectManifest.Policy

  @supported_version "0.1"
  @max_manifest_bytes 1_048_576
  @max_decoded_depth 64
  @max_decoded_nodes 10_000
  @max_decoded_containers 2_000
  @decode_timeout_ms 5_000
  @decode_max_heap_words 4_000_000
  @microusd_per_usd 1_000_000
  @schema_path Path.expand("../../schemas/project.schema.json", __DIR__)
  @external_resource @schema_path
  @raw_schema @schema_path |> File.read!() |> Jason.decode!()

  require JSONSchex.Schema
  @compiled_schema JSONSchex.Schema.compile!(@raw_schema)

  @command_keys ~w(install lint typecheck test integrationTest build start)
  @verification_defaults %{
    "requireDifferentBackend" => false,
    "requireUiEvidence" => false
  }
  @restriction_keys ~w(protectedPaths prohibitedActions allowedNetworkDomains)

  @enforce_keys [
    :schema_version,
    :project,
    :commands,
    :requested_autonomy,
    :autonomy,
    :verification,
    :budgets,
    :restrictions
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: String.t(),
          project: map(),
          commands: map(),
          requested_autonomy: map(),
          autonomy: map(),
          verification: map(),
          budgets: map(),
          restrictions: map()
        }

  @doc "Loads a `.yaml`, `.yml`, or `.json` manifest without executing any declared command."
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, [Error.t()]}
  def load(path, opts \\ []) when is_binary(path) do
    with {:ok, format} <- format_from_path(path),
         {:ok, stat} <- stat_file(path),
         :ok <- validate_size(stat.size),
         {:ok, content} <- read_file(path) do
      load_string(content, format, opts)
    end
  end

  @doc "Parses and validates an in-memory YAML or JSON manifest."
  @spec load_string(String.t(), :yaml | :json, keyword()) ::
          {:ok, t()} | {:error, [Error.t()]}
  def load_string(content, format, opts \\ []) when is_binary(content) do
    with :ok <- validate_size(byte_size(content)),
         {:ok, decoded} <- decode(content, format),
         {:ok, manifest} <- validate(decoded, opts) do
      {:ok, manifest}
    end
  end

  @doc "Validates a decoded manifest and returns its policy-bounded normalized representation."
  @spec validate(term(), keyword()) :: {:ok, t()} | {:error, [Error.t()]}
  def validate(decoded, opts \\ []) do
    with :ok <- validate_decoded_structure(decoded),
         :ok <- validate_version(decoded),
         :ok <- validate_schema(decoded),
         {:ok, policy} <- platform_policy(opts),
         :ok <- validate_policy(decoded, policy) do
      {:ok, normalize(decoded, policy)}
    end
  end

  @doc "Returns the only manifest version accepted by this implementation."
  def supported_version, do: @supported_version

  defp decode(content, :json) do
    bounded_decode(fn -> decode_json(content) end)
  end

  defp decode(content, :yaml) do
    with :ok <- reject_yaml_references(content) do
      bounded_decode(fn -> decode_yaml(content) end)
    end
  end

  defp decode(_content, format) do
    {:error,
     [
       error(
         :unsupported_format,
         "/",
         "Unsupported manifest format #{inspect(format)}; expected :yaml or :json."
       )
     ]}
  end

  defp decode_json(content) do
    case Jason.decode(content, objects: :ordered_objects, floats: :decimals) do
      {:ok, decoded} ->
        with :ok <- validate_decoded_structure(decoded) do
          normalize_json(decoded, [])
        end

      {:error, error} ->
        parse_error(:json, Exception.message(error))
    end
  end

  defp decode_yaml(content) do
    case YamlElixir.read_all_from_string(content, maps_as_keywords: true) do
      {:ok, [document]} ->
        with :ok <- validate_decoded_structure(document) do
          case yaml_duplicate_errors(document, []) do
            [] -> decode_yaml_without_atoms(content)
            errors -> {:error, errors}
          end
        end

      {:ok, documents} ->
        {:error,
         [
           error(
             :multiple_documents,
             "/",
             "Expected exactly one YAML document, found #{length(documents)}."
           )
         ]}

      {:error, error} ->
        parse_error(:yaml, Exception.message(error))
    end
  end

  defp decode_yaml_without_atoms(content) do
    case YamlElixir.read_all_from_string(content) do
      {:ok, [decoded]} ->
        with :ok <- validate_decoded_structure(decoded),
             {:ok, decoded} <- preserve_exact_yaml_cost(content, decoded) do
          {:ok, decoded}
        end

      {:error, error} ->
        parse_error(:yaml, Exception.message(error))
    end
  end

  defp preserve_exact_yaml_cost(content, decoded) do
    case YamlElixir.read_all_from_string(content, schema: :failsafe) do
      {:ok, [raw]} ->
        decoded_cost = get_in(decoded, ["budgets", "maxCostUsd"])

        case {decoded_cost, get_in(raw, ["budgets", "maxCostUsd"])} do
          {value, raw_value} when is_number(value) and is_binary(raw_value) ->
            try do
              {:ok, put_in(decoded, ["budgets", "maxCostUsd"], Decimal.new(raw_value))}
            rescue
              Decimal.Error -> {:ok, decoded}
            end

          _value ->
            {:ok, decoded}
        end

      {:error, error} ->
        parse_error(:yaml, Exception.message(error))
    end
  end

  defp bounded_decode(decode_fun) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {result_ref, safe_decode(decode_fun)}) end,
        [
          :monitor,
          {:max_heap_size, %{size: @decode_max_heap_words, kill: true, error_logger: false}}
        ]
      )

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        decoded_resource_error("Manifest decoding exceeded the parser resource boundary.")
    after
      @decode_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor_ref, [:flush])
        end

        decoded_resource_error(
          "Manifest decoding exceeded the #{@decode_timeout_ms} ms time boundary."
        )
    end
  end

  defp safe_decode(decode_fun) do
    decode_fun.()
  rescue
    exception ->
      {:error,
       [
         error(
           :parse_error,
           "/",
           "Manifest decoder failed safely: #{Exception.message(exception)}"
         )
       ]}
  catch
    _kind, _reason ->
      decoded_resource_error("Manifest decoding failed inside the parser boundary.")
  end

  defp decoded_resource_error(message) do
    {:error, [error(:decoded_structure_limit, "/", message)]}
  end

  defp validate_decoded_structure(decoded) do
    case walk_decoded(decoded, [], 0, 0, 0) do
      {:ok, _counts} -> :ok
      {:error, structure_error} -> {:error, [structure_error]}
    end
  end

  defp walk_decoded(value, path, depth, nodes, containers) do
    nodes = nodes + 1

    cond do
      nodes > @max_decoded_nodes ->
        {:error,
         error(
           :maximum_node_count,
           pointer_from_segments(path),
           "Decoded manifest exceeds the maximum of #{@max_decoded_nodes} nodes."
         )}

      decoded_container?(value) ->
        walk_decoded_container(value, path, depth + 1, nodes, containers + 1)

      true ->
        {:ok, {nodes, containers}}
    end
  end

  defp walk_decoded_container(_value, path, depth, _nodes, _containers)
       when depth > @max_decoded_depth do
    {:error,
     error(
       :maximum_nesting_depth,
       pointer_from_segments(path),
       "Decoded manifest exceeds the maximum nesting depth of #{@max_decoded_depth}."
     )}
  end

  defp walk_decoded_container(_value, path, _depth, _nodes, containers)
       when containers > @max_decoded_containers do
    {:error,
     error(
       :maximum_container_count,
       pointer_from_segments(path),
       "Decoded manifest exceeds the maximum of #{@max_decoded_containers} containers."
     )}
  end

  defp walk_decoded_container(value, path, depth, nodes, containers) do
    value
    |> decoded_children()
    |> Enum.reduce_while({:ok, {nodes, containers}}, fn {segment, child},
                                                        {:ok, {node_count, container_count}} ->
      case walk_decoded(
             child,
             path ++ [segment],
             depth,
             node_count,
             container_count
           ) do
        {:ok, counts} -> {:cont, {:ok, counts}}
        {:error, structure_error} -> {:halt, {:error, structure_error}}
      end
    end)
  end

  defp decoded_container?(%Jason.OrderedObject{}), do: true
  defp decoded_container?(%Decimal{}), do: false
  defp decoded_container?(%_struct{}), do: false
  defp decoded_container?(value), do: is_map(value) or is_list(value)

  defp decoded_children(%Jason.OrderedObject{values: values}), do: values

  defp decoded_children(values) when is_list(values) do
    if values != [] and Enum.all?(values, &match?({_, _}, &1)) do
      values
    else
      values |> Enum.with_index() |> Enum.map(fn {value, index} -> {index, value} end)
    end
  end

  defp decoded_children(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
  end

  defp reject_yaml_references(content), do: scan_yaml_references(content, :plain, nil)

  defp scan_yaml_references(<<>>, _state, _previous), do: :ok

  defp scan_yaml_references(<<?\n, rest::binary>>, :comment, _previous),
    do: scan_yaml_references(rest, :plain, ?\n)

  defp scan_yaml_references(<<_byte, rest::binary>>, :comment, previous),
    do: scan_yaml_references(rest, :comment, previous)

  defp scan_yaml_references(<<?', ?', rest::binary>>, :single_quote, _previous),
    do: scan_yaml_references(rest, :single_quote, ?')

  defp scan_yaml_references(<<?', rest::binary>>, :single_quote, _previous),
    do: scan_yaml_references(rest, :plain, ?')

  defp scan_yaml_references(<<byte, rest::binary>>, :single_quote, _previous),
    do: scan_yaml_references(rest, :single_quote, byte)

  defp scan_yaml_references(<<?\\, _escaped, rest::binary>>, :double_quote, _previous),
    do: scan_yaml_references(rest, :double_quote, nil)

  defp scan_yaml_references(<<?\", rest::binary>>, :double_quote, _previous),
    do: scan_yaml_references(rest, :plain, ?\")

  defp scan_yaml_references(<<byte, rest::binary>>, :double_quote, _previous),
    do: scan_yaml_references(rest, :double_quote, byte)

  defp scan_yaml_references(<<?#, rest::binary>>, :plain, previous)
       when previous in [nil, ?\s, ?\t, ?\r, ?\n] do
    scan_yaml_references(rest, :comment, previous)
  end

  defp scan_yaml_references(<<?', rest::binary>>, :plain, _previous),
    do: scan_yaml_references(rest, :single_quote, ?')

  defp scan_yaml_references(<<?\", rest::binary>>, :plain, _previous),
    do: scan_yaml_references(rest, :double_quote, ?\")

  defp scan_yaml_references(<<indicator, rest::binary>>, :plain, previous)
       when indicator in [?&, ?*] do
    if yaml_reference_indicator?(previous, rest) do
      {:error,
       [
         error(
           :yaml_references_not_allowed,
           "/",
           "YAML anchors and aliases are not allowed; duplicate the bounded value explicitly."
         )
       ]}
    else
      scan_yaml_references(rest, :plain, indicator)
    end
  end

  defp scan_yaml_references(<<byte, rest::binary>>, :plain, _previous),
    do: scan_yaml_references(rest, :plain, byte)

  defp yaml_reference_indicator?(previous, <<next, _rest::binary>>) do
    yaml_reference_boundary?(previous) and not yaml_reference_terminator?(next)
  end

  defp yaml_reference_indicator?(_previous, <<>>), do: false

  defp yaml_reference_boundary?(nil), do: true

  defp yaml_reference_boundary?(byte),
    do: byte in [?\s, ?\t, ?\r, ?\n, ?[, ?{, ?,, ?:, ??, ?-]

  defp yaml_reference_terminator?(byte),
    do: byte in [?\s, ?\t, ?\r, ?\n, ?[, ?], ?{, ?}, ?,]

  defp normalize_json(%Jason.OrderedObject{values: values}, path) do
    duplicate_errors = duplicate_errors(values, path)

    {pairs, nested_errors} =
      Enum.map_reduce(values, [], fn {key, value}, errors ->
        case normalize_json(value, path ++ [key]) do
          {:ok, normalized} -> {{key, normalized}, errors}
          {:error, child_errors} -> {{key, value}, errors ++ child_errors}
        end
      end)

    errors = duplicate_errors ++ nested_errors
    if errors == [], do: {:ok, Map.new(pairs)}, else: {:error, errors}
  end

  defp normalize_json(values, path) when is_list(values) do
    {normalized, errors} =
      values
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {value, index}, errors ->
        case normalize_json(value, path ++ [index]) do
          {:ok, child} -> {child, errors}
          {:error, child_errors} -> {value, errors ++ child_errors}
        end
      end)

    if errors == [], do: {:ok, normalized}, else: {:error, errors}
  end

  defp normalize_json(value, _path), do: {:ok, value}

  defp yaml_duplicate_errors(values, path) when is_list(values) do
    if values != [] and Enum.all?(values, &match?({_, _}, &1)) do
      duplicate_errors(values, path) ++
        Enum.flat_map(values, fn {key, value} ->
          yaml_duplicate_errors(value, path ++ [key])
        end)
    else
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} -> yaml_duplicate_errors(value, path ++ [index]) end)
    end
  end

  defp yaml_duplicate_errors(_value, _path), do: []

  defp duplicate_errors(pairs, path) do
    pairs
    |> Enum.frequencies_by(&elem(&1, 0))
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} ->
      error(
        :duplicate_property,
        pointer_from_segments(path ++ [key]),
        "Property is declared more than once."
      )
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp validate_version(%{"schemaVersion" => @supported_version}), do: :ok

  defp validate_version(%{"schemaVersion" => version}) do
    {:error,
     [
       error(
         :unsupported_version,
         "/schemaVersion",
         "Unsupported manifest version #{inspect(version)}; supported version is #{@supported_version}."
       )
     ]}
  end

  defp validate_version(_decoded), do: :ok

  defp validate_schema(decoded) do
    case JSONSchex.validate(@compiled_schema, schema_compatible(decoded)) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         errors
         |> Enum.map(&schema_error/1)
         |> Enum.sort_by(&{&1.path, &1.code, &1.message})}
    end
  end

  defp schema_compatible(%Decimal{} = value), do: decimal_to_schema_float(value)

  defp schema_compatible(%Jason.OrderedObject{values: values}) do
    Map.new(values, fn {key, value} -> {key, schema_compatible(value)} end)
  end

  defp schema_compatible(%_struct{} = value), do: value

  defp schema_compatible(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {key, schema_compatible(value)} end)
  end

  defp schema_compatible(values) when is_list(values), do: Enum.map(values, &schema_compatible/1)
  defp schema_compatible(value), do: value

  defp decimal_to_schema_float(value) do
    Decimal.to_float(value)
  rescue
    Decimal.Error -> bounded_schema_float(value)
    ArgumentError -> bounded_schema_float(value)
  end

  defp bounded_schema_float(value) do
    sign = Decimal.compare(value, Decimal.new(0))
    magnitude = Decimal.abs(value)

    cond do
      sign == :eq -> 0.0
      Decimal.compare(magnitude, Decimal.new("1e308")) == :gt and sign == :lt -> -1.0e308
      Decimal.compare(magnitude, Decimal.new("1e308")) == :gt -> 1.0e308
      sign == :lt -> -2.2250738585072014e-308
      true -> 2.2250738585072014e-308
    end
  end

  defp schema_error(error) do
    code =
      case error.rule do
        :required -> :missing_required_property
        :boolean_schema -> :unknown_property
        _ -> :schema_validation
      end

    message =
      case error.rule do
        :boolean_schema -> "Property is not allowed by the 0.1 manifest schema."
        _ -> JSONSchex.format_error(error)
      end

    error(code, pointer(error.path), message)
  end

  defp normalize(decoded, policy) do
    requested_autonomy =
      decoded["autonomy"]
      |> Map.put_new("createIssues", false)
      |> Map.put_new("deployToStaging", false)
      |> select_keys(Policy.autonomy_keys())

    effective_autonomy =
      Map.new(requested_autonomy, fn {action, requested?} ->
        {action, requested? and authority_allowed?(policy, action)}
      end)

    repository_restrictions = Map.get(decoded, "restrictions", %{})

    restrictions = %{
      "protectedPaths" =>
        union_sorted(repository_restrictions["protectedPaths"], policy.protected_paths),
      "prohibitedActions" =>
        union_sorted(repository_restrictions["prohibitedActions"], policy.prohibited_actions),
      "allowedNetworkDomains" =>
        intersection_sorted(
          repository_restrictions["allowedNetworkDomains"],
          policy.allowed_network_domains
        )
    }

    %__MODULE__{
      schema_version: decoded["schemaVersion"],
      project:
        decoded["project"]
        |> Map.put_new("documentationRoot", "docs")
        |> select_keys(~w(name description status documentationRoot)),
      commands: select_keys(decoded["commands"], @command_keys),
      requested_autonomy: requested_autonomy,
      autonomy: effective_autonomy,
      verification: normalize_verification(decoded["verification"]),
      budgets: normalize_budgets(decoded["budgets"]),
      restrictions: select_keys(restrictions, @restriction_keys)
    }
  end

  defp validate_policy(decoded, policy) do
    errors =
      verification_policy_errors(decoded, policy) ++
        budget_policy_errors(decoded, policy) ++
        autonomy_policy_errors(decoded, policy) ++
        network_policy_errors(decoded, policy)

    errors = Enum.sort_by(errors, &{&1.path, &1.code, &1.message})

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp verification_policy_errors(decoded, policy) do
    boolean_errors =
      policy.required_verification
      |> Enum.reject(&(decoded["verification"][&1] == true))
      |> Enum.sort()
      |> Enum.map(fn requirement ->
        error(
          :platform_policy_conflict,
          "/verification/#{requirement}",
          "Platform policy requires #{requirement} to be true."
        )
      end)

    repository_minimum = decoded["verification"]["minimumCoveragePercent"]

    coverage_errors =
      if coverage_below_platform?(repository_minimum, policy.minimum_coverage_percent) do
        [
          error(
            :platform_policy_conflict,
            "/verification/minimumCoveragePercent",
            "Platform policy requires minimumCoveragePercent to be at least #{policy.minimum_coverage_percent}."
          )
        ]
      else
        []
      end

    boolean_errors ++ coverage_errors
  end

  defp budget_policy_errors(decoded, policy) do
    budgets = decoded["budgets"]

    [
      cost_ceiling_error(budgets["maxCostUsd"], policy.max_cost_microusd),
      integer_ceiling_error(
        budgets["maxRuntimeMinutes"],
        policy.max_runtime_minutes,
        "/budgets/maxRuntimeMinutes",
        "maxRuntimeMinutes"
      ),
      integer_ceiling_error(
        budgets["maxAgentTurns"],
        policy.max_agent_turns,
        "/budgets/maxAgentTurns",
        "maxAgentTurns"
      ),
      integer_ceiling_error(
        budgets["maxRepairCycles"],
        policy.max_repair_cycles,
        "/budgets/maxRepairCycles",
        "maxRepairCycles"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp autonomy_policy_errors(decoded, policy) do
    decoded["autonomy"]
    |> Enum.filter(fn {action, requested?} ->
      requested? == true and not authority_allowed?(policy, action)
    end)
    |> Enum.map(fn {action, _requested?} ->
      error(
        :platform_policy_conflict,
        "/autonomy/#{action}",
        "Repository requests #{action}, but platform policy does not allow it."
      )
    end)
  end

  defp network_policy_errors(decoded, policy) do
    decoded
    |> get_in(["restrictions", "allowedNetworkDomains"])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.reject(fn {domain, _index} ->
      MapSet.member?(policy.allowed_network_domains, domain)
    end)
    |> Enum.map(fn {domain, index} ->
      error(
        :platform_policy_conflict,
        "/restrictions/allowedNetworkDomains/#{index}",
        "Repository requests network domain #{inspect(domain)}, but it is outside the platform allowlist."
      )
    end)
  end

  defp cost_ceiling_error(repository_usd, ceiling_microusd) do
    requested_microusd = Decimal.mult(to_decimal(repository_usd), @microusd_per_usd)

    if Decimal.compare(requested_microusd, Decimal.new(ceiling_microusd)) == :gt do
      error(
        :platform_policy_conflict,
        "/budgets/maxCostUsd",
        "Repository maxCostUsd exceeds the platform ceiling of #{ceiling_microusd} microusd."
      )
    end
  end

  defp integer_ceiling_error(value, ceiling, path, name) when value > ceiling do
    error(
      :platform_policy_conflict,
      path,
      "Repository #{name} value #{value} exceeds the platform ceiling of #{ceiling}."
    )
  end

  defp integer_ceiling_error(_value, _ceiling, _path, _name), do: nil

  defp coverage_below_platform?(nil, platform_minimum), do: platform_minimum > 0

  defp coverage_below_platform?(repository_minimum, platform_minimum) do
    Decimal.compare(to_decimal(repository_minimum), to_decimal(platform_minimum)) == :lt
  end

  defp normalize_budgets(budgets) do
    %{
      "maxCostMicrousd" => usd_to_microusd(budgets["maxCostUsd"]),
      "maxRuntimeMinutes" => budgets["maxRuntimeMinutes"],
      "maxAgentTurns" => budgets["maxAgentTurns"],
      "maxRepairCycles" => budgets["maxRepairCycles"]
    }
  end

  defp normalize_verification(verification) do
    verification =
      @verification_defaults
      |> Map.merge(verification)
      |> select_keys(
        ~w(independent requireDifferentBackend requireDeterministicChecks requireUiEvidence minimumCoveragePercent)
      )

    case verification["minimumCoveragePercent"] do
      %Decimal{} = percent ->
        Map.put(verification, "minimumCoveragePercent", Decimal.to_float(percent))

      _value ->
        verification
    end
  end

  defp usd_to_microusd(value) do
    value
    |> to_decimal()
    |> Decimal.mult(@microusd_per_usd)
    |> Decimal.round(0, :floor)
    |> Decimal.to_integer()
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp platform_policy(opts) do
    case Keyword.get(opts, :platform_policy, Policy.new()) do
      %Policy{} = policy ->
        validate_platform_policy(Policy.enforce(policy))

      attrs when is_map(attrs) ->
        validate_platform_policy(Policy.new(attrs))

      attrs when is_list(attrs) ->
        if Keyword.keyword?(attrs) do
          validate_platform_policy(Policy.new(attrs))
        else
          {:error, [error(:invalid_platform_policy, "/", "Platform policy is invalid.")]}
        end

      _ ->
        {:error, [error(:invalid_platform_policy, "/", "Platform policy is invalid.")]}
    end
  end

  defp validate_platform_policy(policy) do
    if Policy.valid?(policy) do
      {:ok, policy}
    else
      {:error, [error(:invalid_platform_policy, "/", "Platform policy is invalid.")]}
    end
  end

  defp select_keys(map, keys), do: Map.take(map, keys)

  defp authority_allowed?(policy, "deployToProduction") do
    MapSet.member?(policy.allowed_autonomy, "deployToProduction") and
      not MapSet.member?(policy.prohibited_actions, "deploy-to-production")
  end

  defp authority_allowed?(policy, action), do: MapSet.member?(policy.allowed_autonomy, action)

  defp union_sorted(repository_values, platform_values) do
    repository_values
    |> List.wrap()
    |> MapSet.new()
    |> MapSet.union(platform_values)
    |> Enum.sort()
  end

  defp intersection_sorted(repository_values, platform_values) do
    repository_values
    |> List.wrap()
    |> MapSet.new()
    |> MapSet.intersection(platform_values)
    |> Enum.sort()
  end

  defp format_from_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".yaml" ->
        {:ok, :yaml}

      ".yml" ->
        {:ok, :yaml}

      ".json" ->
        {:ok, :json}

      extension ->
        {:error,
         [
           error(
             :unsupported_format,
             "/",
             "Unsupported manifest extension #{inspect(extension)}; expected .yaml, .yml, or .json."
           )
         ]}
    end
  end

  defp stat_file(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> file_error(path, reason)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> file_error(path, reason)
    end
  end

  defp file_error(path, reason) do
    {:error,
     [
       error(
         :read_error,
         "/",
         "Cannot read manifest #{inspect(path)}: #{:file.format_error(reason)}"
       )
     ]}
  end

  defp validate_size(size) when size <= @max_manifest_bytes, do: :ok

  defp validate_size(size) do
    {:error,
     [
       error(
         :manifest_too_large,
         "/",
         "Manifest is #{size} bytes; maximum size is #{@max_manifest_bytes} bytes."
       )
     ]}
  end

  defp parse_error(format, message) do
    {:error,
     [error(:parse_error, "/", "Cannot parse #{String.upcase(to_string(format))}: #{message}")]}
  end

  defp pointer([]), do: "/"

  defp pointer(path) do
    path
    |> Enum.reverse()
    |> Enum.map_join("/", &escape_pointer/1)
    |> then(&("/" <> &1))
  end

  defp pointer_from_segments([]), do: "/"

  defp pointer_from_segments(path) do
    path
    |> Enum.map_join("/", &escape_pointer/1)
    |> then(&("/" <> &1))
  end

  defp escape_pointer(segment) do
    segment
    |> pointer_segment()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp pointer_segment(segment) when is_binary(segment), do: segment
  defp pointer_segment(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp pointer_segment(segment) when is_atom(segment), do: Atom.to_string(segment)
  defp pointer_segment(segment), do: inspect(segment)

  defp error(code, path, message), do: %Error{code: code, path: path, message: message}
end

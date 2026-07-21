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
    with :ok <- validate_version(decoded),
         :ok <- validate_schema(decoded),
         {:ok, policy} <- platform_policy(opts),
         :ok <- validate_policy(decoded, policy) do
      {:ok, normalize(decoded, policy)}
    end
  end

  @doc "Returns the only manifest version accepted by this implementation."
  def supported_version, do: @supported_version

  defp decode(content, :json) do
    case Jason.decode(content, objects: :ordered_objects) do
      {:ok, decoded} -> normalize_json(decoded, [])
      {:error, error} -> parse_error(:json, Exception.message(error))
    end
  end

  defp decode(content, :yaml) do
    case YamlElixir.read_all_from_string(content, maps_as_keywords: true) do
      {:ok, [document]} ->
        case yaml_duplicate_errors(document, []) do
          [] -> decode_yaml_without_atoms(content)
          errors -> {:error, errors}
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

  defp decode_yaml_without_atoms(content) do
    case YamlElixir.read_all_from_string(content) do
      {:ok, [decoded]} -> {:ok, decoded}
      {:error, error} -> parse_error(:yaml, Exception.message(error))
    end
  end

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
    case JSONSchex.validate(@compiled_schema, decoded) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         errors
         |> Enum.map(&schema_error/1)
         |> Enum.sort_by(&{&1.path, &1.code, &1.message})}
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
      verification:
        @verification_defaults
        |> Map.merge(decoded["verification"])
        |> select_keys(
          ~w(independent requireDifferentBackend requireDeterministicChecks requireUiEvidence minimumCoveragePercent)
        ),
      budgets:
        select_keys(
          decoded["budgets"],
          ~w(maxCostUsd maxRuntimeMinutes maxAgentTurns maxRepairCycles)
        ),
      restrictions: select_keys(restrictions, @restriction_keys)
    }
  end

  defp validate_policy(decoded, policy) do
    errors =
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

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp platform_policy(opts) do
    case Keyword.get(opts, :platform_policy, Policy.new()) do
      %Policy{} = policy ->
        {:ok, Policy.enforce(policy)}

      attrs when is_map(attrs) ->
        {:ok, Policy.new(attrs)}

      attrs when is_list(attrs) ->
        if Keyword.keyword?(attrs) do
          {:ok, Policy.new(attrs)}
        else
          {:error, [error(:invalid_platform_policy, "/", "Platform policy is invalid.")]}
        end

      _ ->
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
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp error(code, path, message), do: %Error{code: code, path: path, message: message}
end

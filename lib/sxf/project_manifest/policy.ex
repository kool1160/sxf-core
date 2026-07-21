defmodule Sxf.ProjectManifest.Policy do
  @moduledoc """
  Platform-owned authority ceiling applied after repository manifest validation.

  The default policy grants no mutation authority or network access. Repository restrictions are
  additive, while allowed network domains are intersected with this platform ceiling.
  """

  @autonomy_keys ~w(createIssues createBranches openPullRequests mergeToDefault deployToStaging deployToProduction)

  @mandatory_prohibited_actions ~w(
    delete-production-data
    deploy-to-production
    expose-secrets
    modify-billing
    weaken-branch-protection
  )

  @mandatory_verification ~w(independent requireDeterministicChecks)

  defstruct allowed_autonomy: MapSet.new(),
            protected_paths: MapSet.new(),
            prohibited_actions: MapSet.new(@mandatory_prohibited_actions),
            allowed_network_domains: MapSet.new(),
            required_verification: MapSet.new(@mandatory_verification)

  @type t :: %__MODULE__{
          allowed_autonomy: MapSet.t(String.t()),
          protected_paths: MapSet.t(String.t()),
          prohibited_actions: MapSet.t(String.t()),
          allowed_network_domains: MapSet.t(String.t()),
          required_verification: MapSet.t(String.t())
        }

  @doc "Builds a platform policy without allowing callers to remove mandatory prohibitions."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    enforce(%__MODULE__{
      allowed_autonomy:
        attrs
        |> fetch(:allowed_autonomy)
        |> string_set()
        |> MapSet.intersection(MapSet.new(@autonomy_keys)),
      protected_paths: attrs |> fetch(:protected_paths) |> string_set(),
      prohibited_actions:
        attrs
        |> fetch(:prohibited_actions)
        |> string_set()
        |> MapSet.union(MapSet.new(@mandatory_prohibited_actions)),
      allowed_network_domains: attrs |> fetch(:allowed_network_domains) |> string_set(),
      required_verification: attrs |> fetch(:required_verification) |> string_set()
    })
  end

  @doc false
  def enforce(%__MODULE__{} = policy) do
    %__MODULE__{
      allowed_autonomy:
        policy.allowed_autonomy
        |> string_set()
        |> MapSet.intersection(MapSet.new(@autonomy_keys)),
      protected_paths: string_set(policy.protected_paths),
      prohibited_actions:
        policy.prohibited_actions
        |> string_set()
        |> MapSet.union(MapSet.new(@mandatory_prohibited_actions)),
      allowed_network_domains: string_set(policy.allowed_network_domains),
      required_verification:
        policy.required_verification
        |> string_set()
        |> MapSet.union(MapSet.new(@mandatory_verification))
    }
  end

  @doc false
  def autonomy_keys, do: @autonomy_keys

  defp fetch(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), []))
  end

  defp fetch(attrs, key) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: Keyword.get(attrs, key, []), else: []
  end

  defp string_set(%MapSet{} = values), do: values |> Enum.filter(&is_binary/1) |> MapSet.new()

  defp string_set(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end
end

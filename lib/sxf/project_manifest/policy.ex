defmodule Sxf.ProjectManifest.Policy do
  @moduledoc """
  Platform-owned authority ceiling applied after repository manifest validation.

  The default policy grants no mutation authority or network access. Repository restrictions are
  additive, while authority, network, budget, and verification requests outside this policy fail
  validation.
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
  @verification_keys ~w(
    independent
    requireDeterministicChecks
    requireDifferentBackend
    requireUiEvidence
  )

  @default_max_cost_microusd 15_000_000
  @default_max_runtime_minutes 120
  @default_max_agent_turns 80
  @default_max_repair_cycles 3

  defstruct allowed_autonomy: MapSet.new(),
            protected_paths: MapSet.new(),
            prohibited_actions: MapSet.new(@mandatory_prohibited_actions),
            allowed_network_domains: MapSet.new(),
            required_verification: MapSet.new(@mandatory_verification),
            minimum_coverage_percent: 0,
            max_cost_microusd: @default_max_cost_microusd,
            max_runtime_minutes: @default_max_runtime_minutes,
            max_agent_turns: @default_max_agent_turns,
            max_repair_cycles: @default_max_repair_cycles

  @type t :: %__MODULE__{
          allowed_autonomy: MapSet.t(String.t()),
          protected_paths: MapSet.t(String.t()),
          prohibited_actions: MapSet.t(String.t()),
          allowed_network_domains: MapSet.t(String.t()),
          required_verification: MapSet.t(String.t()),
          minimum_coverage_percent: number(),
          max_cost_microusd: pos_integer(),
          max_runtime_minutes: pos_integer(),
          max_agent_turns: pos_integer(),
          max_repair_cycles: non_neg_integer()
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
      required_verification: attrs |> fetch(:required_verification) |> string_set(),
      minimum_coverage_percent: fetch(attrs, :minimum_coverage_percent, 0),
      max_cost_microusd: fetch(attrs, :max_cost_microusd, @default_max_cost_microusd),
      max_runtime_minutes: fetch(attrs, :max_runtime_minutes, @default_max_runtime_minutes),
      max_agent_turns: fetch(attrs, :max_agent_turns, @default_max_agent_turns),
      max_repair_cycles: fetch(attrs, :max_repair_cycles, @default_max_repair_cycles)
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
        |> MapSet.intersection(MapSet.new(@verification_keys))
        |> MapSet.union(MapSet.new(@mandatory_verification)),
      minimum_coverage_percent: policy.minimum_coverage_percent,
      max_cost_microusd: policy.max_cost_microusd,
      max_runtime_minutes: policy.max_runtime_minutes,
      max_agent_turns: policy.max_agent_turns,
      max_repair_cycles: policy.max_repair_cycles
    }
  end

  @doc false
  def valid?(%__MODULE__{} = policy) do
    valid_percent?(policy.minimum_coverage_percent) and
      positive_integer?(policy.max_cost_microusd) and
      positive_integer?(policy.max_runtime_minutes) and
      positive_integer?(policy.max_agent_turns) and
      is_integer(policy.max_repair_cycles) and policy.max_repair_cycles >= 0
  end

  @doc false
  def autonomy_keys, do: @autonomy_keys

  defp fetch(attrs, key), do: fetch(attrs, key, [])

  defp fetch(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp fetch(attrs, key, default) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: Keyword.get(attrs, key, default), else: default
  end

  defp string_set(%MapSet{} = values), do: values |> Enum.filter(&is_binary/1) |> MapSet.new()

  defp string_set(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp valid_percent?(value) when is_number(value), do: value >= 0 and value <= 100
  defp valid_percent?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
end

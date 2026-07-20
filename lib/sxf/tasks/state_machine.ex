defmodule Sxf.Tasks.StateMachine do
  @moduledoc """
  Pure, provider-independent lifecycle rules for durable SXF tasks.

  `legal?/2` answers only whether an edge exists. `validate/3` also evaluates the durable
  preconditions assembled by `Sxf.Tasks` from attempts, leases, budgets, blockers, evidence, and
  human decisions.
  """

  @states ~w(
    DISCOVERED
    SPECIFIED
    PLANNED
    READY
    IMPLEMENTING
    CI_RUNNING
    VERIFYING
    CHANGES_REQUESTED
    APPROVED
    STAGING
    RELEASE_READY
    DEPLOYED
    FAILED
    BLOCKED
    CANCELLED
  )

  @permanently_terminal ~w(DEPLOYED)
  @reopenable_terminal ~w(FAILED CANCELLED)
  @terminal @permanently_terminal ++ @reopenable_terminal
  @nonterminal @states -- @terminal

  @forward_edges %{
    "DISCOVERED" => ~w(SPECIFIED),
    "SPECIFIED" => ~w(PLANNED),
    "PLANNED" => ~w(READY),
    "READY" => ~w(IMPLEMENTING),
    "IMPLEMENTING" => ~w(CI_RUNNING),
    "CI_RUNNING" => ~w(VERIFYING CHANGES_REQUESTED),
    "VERIFYING" => ~w(APPROVED CHANGES_REQUESTED),
    "CHANGES_REQUESTED" => ~w(IMPLEMENTING),
    "APPROVED" => ~w(STAGING CHANGES_REQUESTED),
    "STAGING" => ~w(RELEASE_READY CHANGES_REQUESTED),
    "RELEASE_READY" => ~w(DEPLOYED CHANGES_REQUESTED),
    "BLOCKED" => (@nonterminal -- ["BLOCKED"]) ++ ~w(FAILED CANCELLED),
    "FAILED" => ~w(READY),
    "CANCELLED" => ~w(READY),
    "DEPLOYED" => []
  }

  @edges Map.new(@forward_edges, fn {state, destinations} ->
           operational_destinations =
             if state in @nonterminal and state != "BLOCKED" do
               destinations ++ ~w(BLOCKED FAILED CANCELLED)
             else
               destinations
             end

           {state, Enum.uniq(operational_destinations)}
         end)

  @type state :: String.t()
  @type validation_error :: atom() | {:resume_state_mismatch, state() | nil}

  def states, do: @states
  def terminal_states, do: @terminal
  def nonterminal_states, do: @nonterminal
  def permanently_terminal_states, do: @permanently_terminal
  def reopenable_terminal_states, do: @reopenable_terminal
  def edges, do: @edges

  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal

  @spec legal?(state() | nil, state()) :: boolean()
  def legal?(nil, "DISCOVERED"), do: true

  def legal?(prior_state, resulting_state) do
    resulting_state in Map.get(@edges, prior_state, [])
  end

  @spec outgoing(state()) :: [state()]
  def outgoing(state), do: Map.get(@edges, state, [])

  @spec incoming(state()) :: [state() | nil]
  def incoming(state) do
    creation = if state == "DISCOVERED", do: [nil], else: []
    creation ++ for({prior, destinations} <- @edges, state in destinations, do: prior)
  end

  @spec validate(state() | nil, state(), map()) :: :ok | {:error, validation_error()}
  def validate(prior_state, resulting_state, context \\ %{}) do
    cond do
      resulting_state not in @states ->
        {:error, :unknown_resulting_state}

      prior_state != nil and prior_state not in @states ->
        {:error, :unknown_prior_state}

      not legal?(prior_state, resulting_state) ->
        {:error, :illegal_transition}

      true ->
        validate_preconditions(prior_state, resulting_state, context)
    end
  end

  defp validate_preconditions(nil, "DISCOVERED", _context), do: :ok

  defp validate_preconditions(prior, "BLOCKED", context) when prior != "BLOCKED" do
    require_flag(context, :active_blocker?, :active_blocker_required)
  end

  defp validate_preconditions("BLOCKED", "FAILED", context) do
    require_flag(context, :terminal_failure?, :terminal_failure_classification_required)
  end

  defp validate_preconditions("BLOCKED", "CANCELLED", context) do
    require_flag(context, :cancellation_authorized?, :cancellation_authorization_required)
  end

  defp validate_preconditions("BLOCKED", resulting_state, context) do
    with :ok <- require_flag(context, :blockers_resolved?, :active_blockers_remain),
         :ok <- require_resume_state(context, resulting_state),
         :ok <- maybe_require_execution_context(resulting_state, context) do
      :ok
    end
  end

  defp validate_preconditions(prior, "IMPLEMENTING", context)
       when prior in ["READY", "CHANGES_REQUESTED"] do
    with :ok <- require_flag(context, :attempt_active?, :active_attempt_required),
         :ok <- require_flag(context, :lease_active?, :active_lease_required),
         :ok <- require_flag(context, :budget_available?, :available_budget_required),
         :ok <- maybe_require_repair_budget(prior, context) do
      :ok
    end
  end

  defp validate_preconditions("CI_RUNNING", resulting_state, context)
       when resulting_state in ["VERIFYING", "CHANGES_REQUESTED"] do
    require_flag(context, :check_evidence?, :finalized_check_evidence_required)
  end

  defp validate_preconditions("VERIFYING", resulting_state, context)
       when resulting_state in ["APPROVED", "CHANGES_REQUESTED"] do
    require_flag(context, :verification_evidence?, :finalized_verification_evidence_required)
  end

  defp validate_preconditions("RELEASE_READY", "DEPLOYED", context) do
    require_flag(context, :deploy_approved?, :deploy_approval_required)
  end

  defp validate_preconditions(prior, "READY", context)
       when prior in @reopenable_terminal do
    with :ok <- require_flag(context, :reopen_approved?, :reopen_approval_required),
         :ok <- require_flag(context, :budget_available?, :available_budget_required) do
      :ok
    end
  end

  defp validate_preconditions(_prior, "FAILED", context) do
    require_flag(context, :terminal_failure?, :terminal_failure_classification_required)
  end

  defp validate_preconditions(_prior, "CANCELLED", context) do
    require_flag(context, :cancellation_authorized?, :cancellation_authorization_required)
  end

  defp validate_preconditions(_prior, _resulting_state, _context), do: :ok

  defp maybe_require_execution_context("IMPLEMENTING", context) do
    with :ok <- require_flag(context, :attempt_active?, :active_attempt_required),
         :ok <- require_flag(context, :lease_active?, :active_lease_required),
         :ok <- require_flag(context, :budget_available?, :available_budget_required) do
      :ok
    end
  end

  defp maybe_require_execution_context(_resulting_state, _context), do: :ok

  defp maybe_require_repair_budget("CHANGES_REQUESTED", context) do
    require_flag(context, :repair_budget_available?, :repair_budget_required)
  end

  defp maybe_require_repair_budget(_prior, _context), do: :ok

  defp require_resume_state(context, resulting_state) do
    case Map.get(context, :resume_state) do
      ^resulting_state -> :ok
      resume_state -> {:error, {:resume_state_mismatch, resume_state}}
    end
  end

  defp require_flag(context, key, error) do
    if Map.get(context, key, false), do: :ok, else: {:error, error}
  end
end

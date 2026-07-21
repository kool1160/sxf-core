defmodule Sxf.Execution.Claim do
  @moduledoc "A durable, fenced execution claim loaded from the task ledger."

  @enforce_keys [:task, :attempt, :lease, :budgets]
  defstruct [
    :task,
    :attempt,
    :lease,
    :budgets,
    :runtime_deadline_at,
    renewal_sequence: 0,
    replayed?: false
  ]

  @type t :: %__MODULE__{
          task: term(),
          attempt: term(),
          lease: term(),
          budgets: [term()],
          runtime_deadline_at: DateTime.t() | nil,
          renewal_sequence: non_neg_integer(),
          replayed?: boolean()
        }
end

defmodule Sxf.Execution.Context do
  @moduledoc "Provider-neutral input passed across execution boundaries."

  @enforce_keys [:claim, :actor_id, :correlation_id, :started_at]
  defstruct [:claim, :actor_id, :correlation_id, :started_at, :workspace, :sandbox, options: %{}]

  @type t :: %__MODULE__{
          claim: Sxf.Execution.Claim.t(),
          actor_id: Ecto.UUID.t(),
          correlation_id: Ecto.UUID.t(),
          started_at: DateTime.t(),
          workspace: term(),
          sandbox: term(),
          options: map()
        }
end

defmodule Sxf.Execution.Event do
  @moduledoc "A sequenced backend observation. Usage values are non-negative integer deltas."

  @enforce_keys [:id, :sequence, :kind, :occurred_at]
  defstruct [
    :id,
    :idempotency_key,
    :sequence,
    :kind,
    :occurred_at,
    :session_id,
    payload: %{},
    usage: %{}
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          idempotency_key: String.t() | nil,
          sequence: pos_integer(),
          kind: atom(),
          occurred_at: DateTime.t(),
          session_id: String.t() | nil,
          payload: map(),
          usage: map()
        }
end

defmodule Sxf.Execution.Result do
  @moduledoc "A provider-neutral terminal result for one backend invocation."

  @outcomes ~w(success deterministic_failure timeout cancelled backend_unavailable)a
  @enforce_keys [:outcome]
  defstruct [:outcome, :reason, metadata: %{}]

  @type t :: %__MODULE__{outcome: atom(), reason: String.t() | nil, metadata: map()}

  def outcomes, do: @outcomes
end

defmodule Sxf.Execution.TaskStore do
  @moduledoc "Durable authority used by the coordinator. Implementations must be transactional."

  alias Sxf.Execution.{Claim, Event}

  @callback claim_next(map()) :: {:ok, Claim.t() | nil} | {:error, term()}
  @callback renew_lease(Claim.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback record_event(Claim.t(), Event.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback enforce_runtime_timeout(Claim.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback finish(Claim.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  @callback active_claims(String.t()) :: [Claim.t()]
  @callback interrupt(Claim.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback reconcile_expired(DateTime.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
end

defmodule Sxf.Execution.AgentBackend do
  @moduledoc "Provider-neutral agent runtime contract. Backends may not mutate durable limits."

  alias Sxf.Execution.{Context, Result}

  @callback capabilities() :: map()
  @callback start(Context.t(), (Sxf.Execution.Event.t() -> :ok | {:error, term()})) ::
              {:ok, Result.t()} | {:error, :unavailable | term()}
  @callback resume(Context.t(), (Sxf.Execution.Event.t() -> :ok | {:error, term()})) ::
              {:ok, Result.t()} | {:error, :unavailable | term()}
  @callback inspect(Context.t()) :: {:ok, :running | :finished | :missing} | {:error, term()}
  @callback cancel(Context.t()) :: :ok | {:error, term()}
end

defmodule Sxf.Execution.WorkspaceBackend do
  @moduledoc """
  Provider-neutral workspace lifecycle contract.

  Prepared references and release operations must be scoped to the context's attempt and fencing
  token so cleanup from an older attempt cannot remove a newer attempt's resources.
  """

  alias Sxf.Execution.Context

  @callback prepare(Context.t()) :: {:ok, term()} | {:error, :unavailable | term()}
  @callback inspect(Context.t()) :: {:ok, term()} | {:error, term()}
  @callback release(Context.t()) :: :ok | {:error, term()}
end

defmodule Sxf.Execution.SandboxBackend do
  @moduledoc """
  Provider-neutral sandbox lifecycle contract.

  Prepared references and release operations must be scoped to the context's attempt and fencing
  token so cleanup from an older attempt cannot terminate a newer attempt's sandbox.
  """

  alias Sxf.Execution.Context

  @callback prepare(Context.t()) :: {:ok, term()} | {:error, :unavailable | term()}
  @callback inspect(Context.t()) :: {:ok, term()} | {:error, term()}
  @callback release(Context.t()) :: :ok | {:error, term()}
end

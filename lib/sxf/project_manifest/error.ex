defmodule Sxf.ProjectManifest.Error do
  @moduledoc "A structured, actionable connected-project manifest validation failure."

  @enforce_keys [:code, :path, :message]
  defstruct [:code, :path, :message]

  @type t :: %__MODULE__{
          code: atom(),
          path: String.t(),
          message: String.t()
        }
end

defmodule Sxf.Identifiers do
  @moduledoc """
  Generates and validates provider-independent durable identifiers.

  Domain IDs and correlation IDs use canonical UUID strings. Callers may generate an ID before
  submitting a command, which lets a retried create command address the same durable record.
  """

  @spec generate() :: Ecto.UUID.t()
  def generate, do: Ecto.UUID.generate()

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  def valid?(_value), do: false
end

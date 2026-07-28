defmodule Sxf.GitHub.Transport do
  @moduledoc """
  Injectable HTTP boundary for the GitHub control-plane adapter.

  Requests are maps containing `:method`, `:path`, `:headers`, and optionally `:json`. Transport
  implementations return decoded response bodies and normalized response headers. Callers must
  treat authorization values as secrets and must never include a request map in an error.
  """

  @type request :: %{
          required(:method) => atom(),
          required(:path) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          optional(:json) => map()
        }

  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:headers) => %{optional(String.t()) => String.t()},
          required(:body) => term()
        }

  @callback request(request()) :: {:ok, response()} | {:error, term()}

  @doc false
  def request(transport, request) when is_function(transport, 1) do
    safe_request(fn -> transport.(request) end)
  end

  def request(transport, request) when is_atom(transport) do
    safe_request(fn -> transport.request(request) end)
  end

  def request(_transport, _request), do: {:error, :invalid_transport}

  defp safe_request(fun) do
    case fun.() do
      {:ok, %{status: status, headers: headers, body: _body} = response}
      when is_integer(status) and status >= 0 ->
        {:ok, %{response | headers: normalize_headers(headers)}}

      {:error, _reason} ->
        {:error, :transport_error}

      _other ->
        {:error, :malformed_transport_response}
    end
  rescue
    _exception -> {:error, :transport_error}
  catch
    _kind, _reason -> {:error, :transport_error}
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} ->
      {key |> to_string() |> String.downcase(), header_value(value)}
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} ->
      {key |> to_string() |> String.downcase(), header_value(value)}
    end)
  end

  defp normalize_headers(_headers), do: %{}

  defp header_value([value | _]), do: to_string(value)
  defp header_value(value), do: to_string(value)
end

defmodule Sxf.GitHub.HttpcTransport do
  @moduledoc """
  OTP HTTP transport for the local GitHub control plane.

  Tests inject a fake transport; this module is never required by focused or root tests.
  """

  @behaviour Sxf.GitHub.Transport

  @api_base_url "https://api.github.com"

  @impl true
  def request(request) do
    url = String.to_charlist(@api_base_url <> request.path)

    headers =
      Enum.map(request.headers, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)

    http_request =
      case Map.fetch(request, :json) do
        {:ok, body} ->
          {url, headers, ~c"application/json", Jason.encode!(body)}

        :error ->
          {url, headers}
      end

    http_options = [timeout: 15_000, connect_timeout: 5_000, autoredirect: false]
    request_options = [body_format: :binary]

    case :httpc.request(request.method, http_request, http_options, request_options) do
      {:ok, {{_http_version, status, _reason_phrase}, response_headers, body}} ->
        {:ok,
         %{
           status: status,
           headers: response_headers,
           body: decode_body(body)
         }}

      {:error, _reason} ->
        {:error, :transport_error}
    end
  end

  defp decode_body(""), do: nil

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end
end

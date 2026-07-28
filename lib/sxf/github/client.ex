defmodule Sxf.GitHub.Client.Failure do
  @moduledoc """
  Secret-free classification of a GitHub or transport failure.
  """

  defstruct [:kind, :status, :retry_at, :provider_request_id, rate_limit: %{}]
end

defmodule Sxf.GitHub.Client do
  @moduledoc """
  Minimal read-only GitHub REST client used by the bounded M3 issue poller.
  """

  alias Sxf.GitHub.AppAuth.InstallationToken
  alias Sxf.GitHub.Client.Failure
  alias Sxf.GitHub.Transport

  @doc false
  def expect_success(response, opts \\ []) do
    metadata = response_metadata(response.headers)

    if response.status in 200..299 do
      {:ok, Map.merge(response, metadata)}
    else
      {:error, classify_failure(response, metadata, opts)}
    end
  end

  @doc """
  Reads the repository by stable GitHub database ID.
  """
  def get_repository(%InstallationToken{} = token, repository_id, opts) do
    request_json(
      token,
      %{method: :get, path: "/repositories/#{repository_id}"},
      opts
    )
  end

  @doc """
  Reads one explicitly numbered page from the shared GitHub Issues endpoint.
  """
  def list_issues(%InstallationToken{} = token, owner, name, page, per_page, opts) do
    query =
      URI.encode_query([
        {"state", "open"},
        {"labels", "sxf:ready"},
        {"sort", "updated"},
        {"direction", "asc"},
        {"per_page", Integer.to_string(per_page)},
        {"page", Integer.to_string(page)}
      ])

    request_json(
      token,
      %{
        method: :get,
        path: "/repos/#{URI.encode(owner)}/#{URI.encode(name)}/issues?#{query}"
      },
      opts
    )
  end

  defp request_json(token, request, opts) do
    request =
      Map.put(request, :headers, installation_headers(token.value))

    with {:ok, response} <-
           Transport.request(opts[:transport] || Sxf.GitHub.HttpcTransport, request),
         {:ok, response} <- expect_success(response, opts) do
      {:ok, response}
    else
      {:error, %Failure{} = failure} ->
        {:error, failure}

      {:error, reason} ->
        {:error, %Failure{kind: reason}}
    end
  end

  defp installation_headers(token) do
    [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer " <> token},
      {"user-agent", "sxf-core"},
      {"x-github-api-version", "2026-03-10"}
    ]
  end

  defp classify_failure(response, metadata, opts) do
    now = safe_now(opts)
    retry_at = retry_at(response.headers, now)

    kind =
      cond do
        response.status in [403, 429] and rate_limited?(response) ->
          :rate_limited

        response.status == 401 ->
          :authentication_failed

        response.status == 403 ->
          :permission_denied

        response.status == 404 ->
          :repository_unavailable

        response.status == 422 ->
          :provider_rejected_request

        response.status in 500..599 ->
          :provider_unavailable

        true ->
          :provider_error
      end

    %Failure{
      kind: kind,
      status: response.status,
      retry_at: if(kind == :rate_limited, do: retry_at),
      provider_request_id: metadata.provider_request_ids |> List.first(),
      rate_limit: metadata.rate_limit
    }
  end

  defp rate_limited?(response) do
    remaining = header(response.headers, "x-ratelimit-remaining")
    retry_after = header(response.headers, "retry-after")

    message =
      if is_map(response.body) and is_binary(response.body["message"]) do
        String.downcase(response.body["message"])
      else
        ""
      end

    response.status == 429 or remaining == "0" or not is_nil(retry_after) or
      String.contains?(message, "secondary rate limit") or
      String.contains?(message, "rate limit")
  end

  defp retry_at(headers, now) do
    with value when not is_nil(value) <- header(headers, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(value) do
      DateTime.add(now, seconds, :second)
    else
      _other ->
        case header(headers, "x-ratelimit-reset") do
          nil ->
            nil

          value ->
            case Integer.parse(value) do
              {unix, ""} when unix >= 0 -> DateTime.from_unix!(unix)
              _other -> nil
            end
        end
    end
  end

  defp safe_now(opts) do
    now_fn = opts[:now_fn] || fn -> DateTime.utc_now() end

    case now_fn.() do
      %DateTime{} = now -> DateTime.truncate(now, :second)
      _other -> ~U[1970-01-01 00:00:00Z]
    end
  rescue
    _exception -> ~U[1970-01-01 00:00:00Z]
  end

  defp response_metadata(headers) do
    request_ids =
      case safe_request_id(header(headers, "x-github-request-id")) do
        nil -> []
        value -> [value]
      end

    %{
      provider_request_ids: request_ids,
      rate_limit: %{
        limit: parse_integer(header(headers, "x-ratelimit-limit")),
        remaining: parse_integer(header(headers, "x-ratelimit-remaining")),
        reset_at: parse_reset(header(headers, "x-ratelimit-reset")),
        resource: safe_rate_resource(header(headers, "x-ratelimit-resource"))
      }
    }
  end

  defp safe_request_id(value) when is_binary(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9:-]{1,128}\z/), do: value
  end

  defp safe_request_id(_value), do: nil

  defp safe_rate_resource(value) when is_binary(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9_-]{1,64}\z/), do: value
  end

  defp safe_rate_resource(_value), do: nil

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_reset(nil), do: nil

  defp parse_reset(value) do
    case Integer.parse(value) do
      {unix, ""} when unix >= 0 -> DateTime.from_unix!(unix)
      _other -> nil
    end
  end

  defp header(headers, name) when is_map(headers), do: Map.get(headers, name)
  defp header(_headers, _name), do: nil
end

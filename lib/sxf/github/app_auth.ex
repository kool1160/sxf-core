defmodule Sxf.GitHub.AppAuth.InstallationToken do
  @moduledoc false

  defstruct [:value, :expires_at, provider_request_ids: [], rate_limit: %{}]
end

defimpl Inspect, for: Sxf.GitHub.AppAuth.InstallationToken do
  import Inspect.Algebra

  def inspect(token, opts) do
    concat([
      "#Sxf.GitHub.AppAuth.InstallationToken<",
      to_doc(
        %{
          value: "[REDACTED]",
          expires_at: token.expires_at,
          provider_request_ids: token.provider_request_ids,
          rate_limit: token.rate_limit
        },
        opts
      ),
      ">"
    ])
  end
end

defmodule Sxf.GitHub.AppAuth do
  @moduledoc """
  GitHub App JWT signing and repository-scoped installation-token minting.

  Private keys enter only through an injected resolver. Returned installation tokens redact their
  value from inspection, and all public errors contain stable classifications rather than provider
  bodies, headers, tokens, or key material.
  """

  alias Sxf.GitHub.AppAuth.InstallationToken
  alias Sxf.GitHub.Client
  alias Sxf.GitHub.Transport

  @jwt_backdate_seconds 60
  @jwt_lifetime_seconds 600
  @accepted_permissions %{
    "contents" => "write",
    "issues" => "read",
    "pull_requests" => "write"
  }

  @doc """
  Generates a short-lived RS256 GitHub App JWT from injected trusted inputs.
  """
  def generate_jwt(opts) do
    with {:ok, now} <- trusted_now(opts),
         {:ok, app_id} <- required_app_id(opts),
         {:ok, pem} <- resolve_private_key(opts),
         {:ok, key} <- decode_rsa_private_key(pem) do
      issued_at = DateTime.to_unix(now) - @jwt_backdate_seconds

      header = %{"alg" => "RS256", "typ" => "JWT"}

      claims = %{
        "iat" => issued_at,
        "exp" => issued_at + @jwt_lifetime_seconds,
        "iss" => app_id
      }

      signing_input =
        base64url(Jason.encode!(header)) <> "." <> base64url(Jason.encode!(claims))

      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> base64url(signature)}
    end
  end

  @doc """
  Exchanges one App JWT for an installation token limited to the registered repository.
  """
  def mint_installation_token(opts) do
    with {:ok, installation_id} <- positive_integer(opts[:installation_id], :installation_id),
         {:ok, repository_id} <- positive_integer(opts[:repository_id], :repository_id),
         {:ok, jwt} <- generate_jwt(opts),
         {:ok, response} <-
           Transport.request(opts[:transport] || Sxf.GitHub.HttpcTransport, %{
             method: :post,
             path: "/app/installations/#{installation_id}/access_tokens",
             headers: app_headers(jwt),
             json: %{
               "repository_ids" => [repository_id],
               "permissions" => @accepted_permissions
             }
           }),
         {:ok, response} <- Client.expect_success(response, opts),
         {:ok, token} <-
           validate_token_response(response, installation_id, repository_id) do
      {:ok, token}
    else
      {:error, %Client.Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_token_response(response, installation_id, repository_id) do
    body = response.body

    cond do
      not is_map(body) ->
        {:error, :malformed_installation_token_response}

      not valid_secret?(body["token"]) ->
        {:error, :malformed_installation_token_response}

      not valid_expiry?(body["expires_at"]) ->
        {:error, :malformed_installation_token_response}

      Map.has_key?(body, "installation_id") and
          not same_integer?(body["installation_id"], installation_id) ->
        {:error, :installation_mismatch}

      body["repository_selection"] not in [nil, "selected"] ->
        {:error, :repository_scope_mismatch}

      not repositories_match?(body["repositories"], repository_id) ->
        {:error, :repository_scope_mismatch}

      not permissions_match?(body["permissions"]) ->
        {:error, :permission_scope_mismatch}

      true ->
        {:ok,
         %InstallationToken{
           value: body["token"],
           expires_at: parse_datetime(body["expires_at"]),
           provider_request_ids: response.provider_request_ids,
           rate_limit: response.rate_limit
         }}
    end
  end

  defp repositories_match?(nil, _repository_id), do: true

  defp repositories_match?([repository], repository_id) when is_map(repository) do
    same_integer?(repository["id"], repository_id)
  end

  defp repositories_match?(_repositories, _repository_id), do: false

  defp permissions_match?(permissions) when is_map(permissions) do
    normalized =
      Map.new(permissions, fn {key, value} ->
        {to_string(key), value |> to_string() |> String.downcase()}
      end)

    required? =
      Enum.all?(@accepted_permissions, fn {key, value} ->
        Map.get(normalized, key) == value
      end)

    material_permissions? =
      Enum.all?(normalized, fn
        {"metadata", value} ->
          value in ["read", "none"]

        {key, value} when is_map_key(@accepted_permissions, key) ->
          value == Map.fetch!(@accepted_permissions, key)

        {_key, "none"} ->
          true

        {_key, _value} ->
          false
      end)

    required? and material_permissions?
  end

  defp permissions_match?(_permissions), do: false

  defp trusted_now(opts) do
    now_fn = opts[:now_fn] || fn -> DateTime.utc_now() end

    case now_fn.() do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :second)}
      _other -> {:error, :invalid_trusted_time}
    end
  rescue
    _exception -> {:error, :invalid_trusted_time}
  end

  defp required_app_id(opts) do
    case opts[:app_id] do
      value when is_integer(value) and value > 0 ->
        {:ok, Integer.to_string(value)}

      value when is_binary(value) ->
        if String.match?(value, ~r/\A[1-9][0-9]*\z/),
          do: {:ok, value},
          else: {:error, :invalid_app_id}

      _other ->
        {:error, :invalid_app_id}
    end
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_auth_field, field}}
    end
  end

  defp positive_integer(_value, field), do: {:error, {:invalid_auth_field, field}}

  defp resolve_private_key(opts) do
    resolver = opts[:private_key_resolver]

    result =
      cond do
        is_function(resolver, 0) -> resolver.()
        is_atom(resolver) and function_exported?(resolver, :resolve, 0) -> resolver.resolve()
        true -> {:error, :private_key_unavailable}
      end

    case result do
      {:ok, pem} when is_binary(pem) -> {:ok, pem}
      _other -> {:error, :private_key_unavailable}
    end
  rescue
    _exception -> {:error, :private_key_unavailable}
  catch
    _kind, _reason -> {:error, :private_key_unavailable}
  end

  defp decode_rsa_private_key(pem) do
    with [entry] <- :public_key.pem_decode(pem),
         false <- encrypted_entry?(entry),
         key <- :public_key.pem_entry_decode(entry),
         true <- rsa_private_key?(key) do
      {:ok, key}
    else
      _other -> {:error, :unsupported_private_key}
    end
  rescue
    _exception -> {:error, :malformed_private_key}
  catch
    _kind, _reason -> {:error, :malformed_private_key}
  end

  defp encrypted_entry?({_type, _der, encryption}) when encryption != :not_encrypted, do: true
  defp encrypted_entry?(_entry), do: false

  defp rsa_private_key?(key), do: is_tuple(key) and elem(key, 0) == :RSAPrivateKey

  defp app_headers(jwt) do
    [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer " <> jwt},
      {"user-agent", "sxf-core"},
      {"x-github-api-version", "2026-03-10"}
    ]
  end

  defp valid_secret?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) > 0

  defp valid_expiry?(value), do: not is_nil(parse_datetime(value))

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp same_integer?(left, right) do
    case positive_integer(left, :value) do
      {:ok, value} -> value == right
      _other -> false
    end
  end

  defp base64url(value), do: Base.url_encode64(value, padding: false)
end

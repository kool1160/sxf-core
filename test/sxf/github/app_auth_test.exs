defmodule Sxf.GitHub.AppAuthTest do
  use ExUnit.Case, async: true

  alias Sxf.GitHub.AppAuth
  alias Sxf.GitHub.AppAuth.InstallationToken
  alias Sxf.GitHub.Client.Failure

  @now ~U[2026-07-28 15:30:45Z]
  @app_id "123456"
  @installation_id 654_321
  @repository_id 987_654
  @token "opaque-installation-token-value"

  setup_all do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
      ])

    %{private_key: private_key, public_key: public_key, pem: pem}
  end

  test "RS256 JWT has the exact bounded claims and verifies with the public key", fixture do
    assert {:ok, jwt} = AppAuth.generate_jwt(auth_opts(fixture.pem))
    [encoded_header, encoded_claims, encoded_signature] = String.split(jwt, ".")

    header = encoded_header |> decode_segment!() |> Jason.decode!()
    claims = encoded_claims |> decode_segment!() |> Jason.decode!()
    signature = decode_segment!(encoded_signature)

    assert header == %{"alg" => "RS256", "typ" => "JWT"}
    assert claims["iss"] == @app_id
    assert claims["iat"] == DateTime.to_unix(@now) - 60
    assert claims["exp"] == claims["iat"] + 600
    assert claims["exp"] == DateTime.to_unix(@now) + 540

    assert :public_key.verify(
             encoded_header <> "." <> encoded_claims,
             :sha256,
             signature,
             fixture.public_key
           )
  end

  test "trusted subsecond clock input is deterministic at the claim boundary", fixture do
    now = ~U[2026-07-28 15:30:45.999999Z]

    assert {:ok, first} =
             AppAuth.generate_jwt(auth_opts(fixture.pem, now_fn: fn -> now end))

    assert {:ok, second} =
             AppAuth.generate_jwt(
               auth_opts(fixture.pem, now_fn: fn -> DateTime.truncate(now, :second) end)
             )

    assert first == second
  end

  test "PKCS#8 RSA private-key PEM is accepted", fixture do
    pkcs8_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:PrivateKeyInfo, fixture.private_key)
      ])

    assert {:ok, jwt} =
             AppAuth.generate_jwt(auth_opts(pkcs8_pem))

    assert jwt |> String.split(".") |> length() == 3
  end

  test "malformed, encrypted, public-only, and unavailable keys fail without disclosure",
       fixture do
    public_pem =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, fixture.public_key)
      ])

    failures = [
      fn -> {:ok, "not a PEM key"} end,
      fn -> {:ok, public_pem} end,
      fn -> {:error, "private-key-secret-detail"} end,
      fn -> raise "private-key-secret-detail" end
    ]

    for resolver <- failures do
      assert {:error, reason} =
               AppAuth.generate_jwt(auth_opts("unused", private_key_resolver: resolver))

      refute inspect(reason) =~ "private-key-secret-detail"
      refute inspect(reason) =~ public_pem
    end
  end

  test "installation token exchange uses the exact path, headers, repository, and permissions",
       fixture do
    parent = self()

    transport = fn request ->
      authorization = header(request.headers, "authorization")

      send(parent, {
        :token_request,
        %{
          method: request.method,
          path: request.path,
          accept: header(request.headers, "accept"),
          bearer?: String.starts_with?(authorization, "Bearer "),
          jwt_segments: authorization |> String.replace_prefix("Bearer ", "") |> segments(),
          body: request.json
        }
      })

      {:ok, token_response()}
    end

    assert {:ok, %InstallationToken{} = token} =
             AppAuth.mint_installation_token(auth_opts(fixture.pem, transport: transport))

    assert token.value == @token
    assert token.expires_at == ~U[2026-07-28 16:00:00Z]

    assert_receive {:token_request, request}
    assert request.method == :post
    assert request.path == "/app/installations/#{@installation_id}/access_tokens"
    assert request.accept == "application/vnd.github+json"
    assert request.bearer?
    assert request.jwt_segments == 3

    assert request.body == %{
             "repository_ids" => [@repository_id],
             "permissions" => %{
               "contents" => "write",
               "issues" => "read",
               "pull_requests" => "write"
             }
           }
  end

  test "wrong installation, repository, selection, and broader permissions fail closed",
       fixture do
    invalid_bodies = [
      Map.put(token_body(), "installation_id", @installation_id + 1),
      put_in(token_body(), ["repositories"], [%{"id" => @repository_id + 1}]),
      Map.put(token_body(), "repository_selection", "all"),
      put_in(token_body(), ["permissions", "administration"], "write"),
      put_in(token_body(), ["permissions", "issues"], "write"),
      Map.delete(token_body(), "permissions")
    ]

    for body <- invalid_bodies do
      transport = fn _request -> {:ok, %{token_response() | body: body}} end

      assert {:error, reason} =
               AppAuth.mint_installation_token(auth_opts(fixture.pem, transport: transport))

      assert reason in [
               :installation_mismatch,
               :repository_scope_mismatch,
               :permission_scope_mismatch
             ]
    end
  end

  test "installation tokens and authorization material are redacted from inspection and failures",
       fixture do
    transport = fn _request -> {:ok, token_response()} end

    assert {:ok, token} =
             AppAuth.mint_installation_token(auth_opts(fixture.pem, transport: transport))

    rendered = inspect(token)
    assert rendered =~ "[REDACTED]"
    refute rendered =~ @token

    leaking_transport = fn request ->
      raise "transport failed with #{inspect(request.headers)} and #{@token}"
    end

    assert {:error, :transport_error} =
             AppAuth.mint_installation_token(auth_opts(fixture.pem, transport: leaking_transport))

    refute inspect(:transport_error) =~ @token

    denied_transport = fn _request ->
      {:ok,
       %{
         status: 401,
         headers: %{"x-github-request-id" => "SAFE-REQUEST-ID"},
         body: %{"message" => "Bearer #{@token}"}
       }}
    end

    assert {:error, %Failure{} = failure} =
             AppAuth.mint_installation_token(auth_opts(fixture.pem, transport: denied_transport))

    assert failure.kind == :authentication_failed
    assert failure.provider_request_id == "SAFE-REQUEST-ID"
    refute inspect(failure) =~ @token
  end

  defp auth_opts(pem, overrides \\ []) do
    Keyword.merge(
      [
        app_id: @app_id,
        installation_id: @installation_id,
        repository_id: @repository_id,
        private_key_resolver: fn -> {:ok, pem} end,
        now_fn: fn -> @now end,
        transport: fn _request -> {:ok, token_response()} end
      ],
      overrides
    )
  end

  defp token_response do
    %{
      status: 201,
      headers: %{
        "x-github-request-id" => "TOKEN-REQUEST-ID",
        "x-ratelimit-limit" => "5000",
        "x-ratelimit-remaining" => "4999",
        "x-ratelimit-reset" => "1785254400"
      },
      body: token_body()
    }
  end

  defp token_body do
    %{
      "token" => @token,
      "expires_at" => "2026-07-28T16:00:00Z",
      "installation_id" => @installation_id,
      "repository_selection" => "selected",
      "repositories" => [%{"id" => @repository_id}],
      "permissions" => %{
        "metadata" => "read",
        "contents" => "write",
        "issues" => "read",
        "pull_requests" => "write"
      }
    }
  end

  defp decode_segment!(value), do: Base.url_decode64!(value, padding: false)
  defp segments(value), do: value |> String.split(".") |> length()

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _other -> nil
    end)
  end
end

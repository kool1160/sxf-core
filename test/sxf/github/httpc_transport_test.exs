defmodule Sxf.GitHub.HttpcTransportTest do
  use ExUnit.Case, async: true

  alias Sxf.GitHub.HttpcTransport

  test "disables redirects and automatic retries at the httpc request boundary" do
    test_process = self()

    request_fun = fn method, request, http_options, request_options ->
      send(test_process, {:httpc_request, method, request, http_options, request_options})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{}"}}
    end

    assert {:ok, %{status: 200, body: %{}}} =
             HttpcTransport.request(
               %{
                 method: :get,
                 path: "/rate_limit",
                 headers: [{"accept", "application/vnd.github+json"}]
               },
               request_fun
             )

    assert_receive {:httpc_request, :get, _request, http_options, [body_format: :binary]}

    assert Keyword.fetch!(http_options, :timeout) == 15_000
    assert Keyword.fetch!(http_options, :connect_timeout) == 5_000
    refute Keyword.fetch!(http_options, :autoredirect)
    assert Keyword.fetch!(http_options, :autoretry) == 0
  end
end

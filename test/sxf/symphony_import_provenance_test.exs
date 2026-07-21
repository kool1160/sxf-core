defmodule Sxf.SymphonyImportProvenanceTest do
  use ExUnit.Case, async: true

  alias Sxf.SymphonyImportProvenance

  test "pinned-source check rejects imported drift hidden by a matching manifest edit" do
    drifted_blob = String.duplicate("a", 40)
    pinned_blob = String.duplicate("b", 40)

    entry = %{
      "upstreamPath" => "SPEC.md",
      "importedPath" => "upstream/openai-symphony/SPEC.md",
      "upstreamGitBlobSha" => drifted_blob,
      "importedGitBlobSha" => drifted_blob,
      "importedContentSha256" => String.duplicate("c", 64),
      "modified" => false
    }

    assert_raise RuntimeError, ~r/pinned upstream blob mismatch.*SPEC\.md/, fn ->
      SymphonyImportProvenance.assert_pinned_blob!(entry, pinned_blob)
    end
  end

  test "pinned-source check accepts the independently resolved blob" do
    pinned_blob = String.duplicate("b", 40)

    entry = %{
      "upstreamPath" => "elixir/mix.exs",
      "importedPath" => "upstream/openai-symphony/elixir/mix.exs",
      "upstreamGitBlobSha" => pinned_blob
    }

    assert :ok = SymphonyImportProvenance.assert_pinned_blob!(entry, pinned_blob)
  end
end

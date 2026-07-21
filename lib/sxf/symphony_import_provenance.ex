defmodule Sxf.SymphonyImportProvenance do
  @moduledoc false

  @spec assert_pinned_blob!(map(), String.t()) :: :ok
  def assert_pinned_blob!(entry, actual_upstream_blob) do
    recorded_upstream_blob = Map.fetch!(entry, "upstreamGitBlobSha")
    upstream_path = Map.fetch!(entry, "upstreamPath")
    imported_path = Map.fetch!(entry, "importedPath")

    if recorded_upstream_blob == actual_upstream_blob do
      :ok
    else
      raise(
        "pinned upstream blob mismatch for #{imported_path} " <>
          "(upstream #{upstream_path}): " <>
          "manifest=#{recorded_upstream_blob} pinned=#{actual_upstream_blob}"
      )
    end
  end
end

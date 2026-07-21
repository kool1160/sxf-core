defmodule Sxf.VerifySymphonyImport do
  @moduledoc false

  @repository "https://github.com/openai/symphony.git"
  @commit "633eae740f807de18007f5a9a25e2e0d206afdf4"
  @import_root "upstream/openai-symphony"
  @manifest_path "upstream/openai-symphony/import-manifest.json"
  @metadata_paths MapSet.new([
                    "upstream/openai-symphony/SOURCE.md",
                    @manifest_path
                  ])
  @modified_upstream_paths MapSet.new([
                             "elixir/config/config.exs",
                             "elixir/lib/symphony_elixir/config/schema.ex",
                             "elixir/lib/symphony_elixir/tracker.ex",
                             "elixir/lib/symphony_elixir/workspace.ex",
                             "elixir/mix.exs",
                             "elixir/mix.lock"
                           ])

  def main(["--generate", upstream_checkout]) do
    files = imported_paths() |> Enum.map(&manifest_entry(&1, upstream_checkout))

    manifest = %{
      "manifestVersion" => 1,
      "upstreamRepository" => @repository,
      "pinnedCommit" => @commit,
      "importRevision" => "issue-17",
      "importedAt" => "2026-07-21",
      "files" => files
    }

    File.write!(@manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")
    IO.puts("generated #{length(files)} Symphony import entries")
  end

  def main([]) do
    manifest = @manifest_path |> File.read!() |> Jason.decode!()

    assert!(manifest["manifestVersion"] == 1, "unexpected manifest version")
    assert!(manifest["upstreamRepository"] == @repository, "unexpected upstream repository")
    assert!(manifest["pinnedCommit"] == @commit, "unexpected pinned commit")

    entries = manifest["files"]
    assert!(is_list(entries), "manifest files must be a list")

    actual_paths = imported_paths()
    recorded_paths = Enum.map(entries, & &1["importedPath"])

    assert!(recorded_paths == Enum.sort(recorded_paths), "manifest entries are not sorted")
    assert!(recorded_paths == actual_paths, "manifest paths do not match imported files")

    assert!(
      length(recorded_paths) == length(Enum.uniq(recorded_paths)),
      "duplicate manifest path"
    )

    Enum.each(entries, &verify_entry!/1)
    verify_retained_notices!()

    modified_count = Enum.count(entries, & &1["modified"])
    IO.puts("verified #{length(entries)} Symphony files (#{modified_count} modified)")
  end

  def main(_args),
    do:
      raise(
        "usage: mix run --no-start scripts/verify_symphony_import.exs [--generate UPSTREAM_CHECKOUT]"
      )

  defp imported_paths do
    File.cwd!()
    |> git_binary!(["ls-files", "-z", @import_root])
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&String.replace(&1, "\\", "/"))
    |> Enum.reject(&MapSet.member?(@metadata_paths, &1))
    |> Enum.sort()
  end

  defp manifest_entry(imported_path, upstream_checkout) do
    upstream_path = upstream_path(imported_path)
    upstream_blob = git!(upstream_checkout, ["rev-parse", "#{@commit}:#{upstream_path}"])
    imported_blob = git!(File.cwd!(), ["rev-parse", ":#{imported_path}"])
    imported_content = git_binary!(File.cwd!(), ["cat-file", "blob", imported_blob])
    modified = MapSet.member?(@modified_upstream_paths, upstream_path)
    notice_present = modification_notice_present?(imported_content, upstream_path)

    %{
      "upstreamRepository" => @repository,
      "pinnedCommit" => @commit,
      "upstreamPath" => upstream_path,
      "importedPath" => imported_path,
      "upstreamGitBlobSha" => upstream_blob,
      "importedGitBlobSha" => imported_blob,
      "importedContentSha256" => sha256(imported_content),
      "modified" => modified,
      "modificationNoticeRequired" => modified,
      "modificationNoticePresent" => notice_present,
      "license" => "Apache-2.0"
    }
  end

  defp verify_entry!(entry) do
    imported_path = entry["importedPath"]
    upstream_path = entry["upstreamPath"]
    modified = entry["modified"]
    notice_required = entry["modificationNoticeRequired"]
    imported_blob = git!(File.cwd!(), ["rev-parse", ":#{imported_path}"])
    imported_content = git_binary!(File.cwd!(), ["cat-file", "blob", imported_blob])

    assert!(
      entry["upstreamRepository"] == @repository,
      "repository mismatch for #{imported_path}"
    )

    assert!(entry["pinnedCommit"] == @commit, "commit mismatch for #{imported_path}")
    assert!(entry["license"] == "Apache-2.0", "license mismatch for #{imported_path}")

    assert!(
      entry["importedGitBlobSha"] == imported_blob,
      "Git blob mismatch for #{imported_path}"
    )

    assert!(
      entry["importedContentSha256"] == sha256(imported_content),
      "SHA-256 mismatch for #{imported_path}"
    )

    assert!(
      modified == MapSet.member?(@modified_upstream_paths, upstream_path),
      "modification state mismatch for #{imported_path}"
    )

    assert!(notice_required == modified, "notice requirement mismatch for #{imported_path}")

    if modified do
      assert!(
        entry["upstreamGitBlobSha"] != imported_blob,
        "modified file matches upstream for #{imported_path}"
      )

      assert!(
        entry["modificationNoticePresent"],
        "manifest notice flag missing for #{imported_path}"
      )

      assert!(
        modification_notice_present?(imported_content, upstream_path),
        "modification notice missing for #{imported_path}"
      )
    else
      assert!(
        entry["upstreamGitBlobSha"] == imported_blob,
        "unmodified file differs from upstream: #{imported_path}"
      )

      refute!(
        entry["modificationNoticePresent"],
        "unmodified file marked with notice: #{imported_path}"
      )
    end
  end

  defp verify_retained_notices! do
    apache = index_blob!("licenses/Apache-2.0.txt")
    notice = index_blob!("licenses/symphony-NOTICE.txt")
    imported_apache = index_blob!("upstream/openai-symphony/LICENSE")
    imported_notice = index_blob!("upstream/openai-symphony/NOTICE")

    assert!(apache == imported_apache, "repository Apache-2.0 text differs from pinned upstream")
    assert!(notice == imported_notice, "repository Symphony NOTICE differs from pinned upstream")
  end

  defp upstream_path("upstream/openai-symphony/elixir/" <> relative), do: "elixir/" <> relative
  defp upstream_path("upstream/openai-symphony/" <> relative), do: relative

  defp modification_notice_present?(content, upstream_path) do
    String.contains?(content, "SXF MODIFICATION NOTICE") and
      String.contains?(content, @commit) and
      String.contains?(content, "original path #{upstream_path}")
  end

  defp index_blob!(path) do
    blob = git!(File.cwd!(), ["rev-parse", ":#{path}"])
    git_binary!(File.cwd!(), ["cat-file", "blob", blob])
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp git!(directory, args) do
    directory
    |> git_binary!(args)
    |> String.trim()
  end

  defp git_binary!(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
  defp refute!(false, _message), do: :ok
  defp refute!(true, message), do: raise(message)
end

Sxf.VerifySymphonyImport.main(System.argv())

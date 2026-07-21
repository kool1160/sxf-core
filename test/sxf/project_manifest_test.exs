defmodule Sxf.ProjectManifestTest do
  use ExUnit.Case, async: true

  alias Sxf.ProjectManifest
  alias Sxf.ProjectManifest.Error
  alias Sxf.ProjectManifest.Policy

  @example_path Path.expand("../../examples/project.sxf.yaml", __DIR__)

  test "loads and normalizes the example YAML manifest conservatively" do
    assert {:ok, %ProjectManifest{} = manifest} = ProjectManifest.load(@example_path)

    assert manifest.schema_version == "0.1"
    assert manifest.project["documentationRoot"] == "docs"
    assert manifest.commands["install"] == "npm ci"
    assert manifest.commands["test"] == "npm test"
    assert manifest.requested_autonomy["createBranches"]
    assert manifest.requested_autonomy["openPullRequests"]
    assert Enum.all?(manifest.autonomy, fn {_action, allowed?} -> allowed? == false end)
    assert manifest.restrictions["allowedNetworkDomains"] == []
    assert "expose-secrets" in manifest.restrictions["prohibitedActions"]
  end

  test "loads JSON and applies stable optional defaults" do
    policy =
      Policy.new(
        allowed_autonomy: ["createBranches", "openPullRequests"],
        allowed_network_domains: ["github.com"]
      )

    manifest =
      valid_manifest()
      |> put_in(["autonomy", "createBranches"], true)
      |> put_in(["autonomy", "openPullRequests"], true)
      |> Map.put("restrictions", %{"allowedNetworkDomains" => ["github.com", "example.com"]})

    path = temporary_file!("project.sxf.json", Jason.encode!(manifest))

    assert {:ok, normalized} =
             ProjectManifest.load(path, platform_policy: policy)

    assert normalized.project["documentationRoot"] == "docs"
    assert normalized.requested_autonomy["createIssues"] == false
    assert normalized.requested_autonomy["deployToStaging"] == false
    assert normalized.autonomy["createBranches"]
    assert normalized.autonomy["openPullRequests"]
    refute normalized.autonomy["mergeToDefault"]
    refute normalized.autonomy["deployToProduction"]
    assert normalized.verification["requireDifferentBackend"] == false
    assert normalized.verification["requireUiEvidence"] == false
    assert normalized.restrictions["allowedNetworkDomains"] == ["github.com"]
  end

  test "equivalent YAML and JSON normalize identically" do
    yaml = File.read!(@example_path)
    {:ok, decoded} = YamlElixir.read_from_string(yaml)

    assert {:ok, yaml_manifest} = ProjectManifest.load_string(yaml, :yaml)
    assert {:ok, json_manifest} = ProjectManifest.load_string(Jason.encode!(decoded), :json)
    assert json_manifest == yaml_manifest
  end

  test "unknown properties at every security-relevant level are actionable errors" do
    manifest =
      valid_manifest()
      |> Map.put("credentials", %{"scope" => "admin"})
      |> Map.put("sandbox", %{"privileged" => true})
      |> put_in(["commands", "release"], "dangerous-release")
      |> put_in(["autonomy", "bypassApproval"], true)
      |> put_in(["verification", "trustBuilder"], true)
      |> put_in(["budgets", "unlimited"], true)

    assert {:error, errors} = ProjectManifest.validate(manifest)

    assert_error(errors, :unknown_property, "/credentials")
    assert_error(errors, :unknown_property, "/sandbox")
    assert_error(errors, :unknown_property, "/commands/release")
    assert_error(errors, :unknown_property, "/autonomy/bypassApproval")
    assert_error(errors, :unknown_property, "/verification/trustBuilder")
    assert_error(errors, :unknown_property, "/budgets/unlimited")

    assert Enum.all?(errors, fn error ->
             error.message =~ "not allowed" and String.starts_with?(error.path, "/")
           end)
  end

  test "missing required commands, budgets, and autonomy settings fail together" do
    manifest =
      valid_manifest()
      |> update_in(["commands"], &Map.drop(&1, ["install", "test"]))
      |> update_in(["budgets"], &Map.drop(&1, ["maxCostUsd", "maxRuntimeMinutes"]))
      |> update_in(
        ["autonomy"],
        &Map.drop(&1, ["createBranches", "mergeToDefault", "deployToProduction"])
      )
      |> Map.delete("verification")

    assert {:error, errors} = ProjectManifest.validate(manifest)

    assert_error(errors, :missing_required_property, "/commands", "install")
    assert_error(errors, :missing_required_property, "/commands", "test")
    assert_error(errors, :missing_required_property, "/budgets", "maxCostUsd")
    assert_error(errors, :missing_required_property, "/budgets", "maxRuntimeMinutes")
    assert_error(errors, :missing_required_property, "/autonomy", "createBranches")
    assert_error(errors, :missing_required_property, "/autonomy", "mergeToDefault")
    assert_error(errors, :missing_required_property, "/autonomy", "deployToProduction")
    assert_error(errors, :missing_required_property, "/", "verification")
  end

  test "unsupported manifest versions fail before normalization" do
    assert {:error,
            [
              %Error{
                code: :unsupported_version,
                path: "/schemaVersion",
                message: message
              }
            ]} = ProjectManifest.validate(%{valid_manifest() | "schemaVersion" => "9.9"})

    assert message =~ "9.9"
    assert message =~ ProjectManifest.supported_version()
  end

  test "malformed YAML and JSON return parse failures" do
    assert {:error, [%Error{code: :parse_error, message: yaml_message}]} =
             ProjectManifest.load_string("project: [", :yaml)

    assert yaml_message =~ "YAML"

    assert {:error, [%Error{code: :parse_error, message: json_message}]} =
             ProjectManifest.load_string(~s({"schemaVersion":), :json)

    assert json_message =~ "JSON"

    assert {:error, [%Error{code: :multiple_documents, message: documents_message}]} =
             ProjectManifest.load_string(
               "schemaVersion: '0.1'\n---\nschemaVersion: '0.1'",
               :yaml
             )

    assert documents_message =~ "2"
  end

  test "duplicate YAML and JSON properties are rejected instead of silently shadowed" do
    yaml = """
    schemaVersion: "0.1"
    schemaVersion: "9.9"
    """

    assert {:error, [%Error{code: :duplicate_property, path: "/schemaVersion"}]} =
             ProjectManifest.load_string(yaml, :yaml)

    json = ~s({"schemaVersion":"0.1","schemaVersion":"9.9"})

    assert {:error, [%Error{code: :duplicate_property, path: "/schemaVersion"}]} =
             ProjectManifest.load_string(json, :json)
  end

  test "repository requests cannot exceed platform authority or remove prohibitions" do
    manifest =
      valid_manifest()
      |> Map.put(
        "autonomy",
        Map.new(Policy.autonomy_keys(), &{&1, true})
      )
      |> Map.put("restrictions", %{
        "protectedPaths" => ["repository-owned/"],
        "prohibitedActions" => [],
        "allowedNetworkDomains" => ["github.com", "exfiltration.invalid"]
      })

    policy =
      Policy.new(
        allowed_autonomy: Policy.autonomy_keys() ++ ["notARealAuthority"],
        protected_paths: [".github/"],
        prohibited_actions: ["platform-only-action"],
        allowed_network_domains: ["github.com", "platform.internal"]
      )

    assert {:ok, normalized} = ProjectManifest.validate(manifest, platform_policy: policy)

    assert normalized.autonomy["createBranches"]

    assert normalized.autonomy["createIssues"]
    assert normalized.autonomy["openPullRequests"]
    assert normalized.autonomy["mergeToDefault"]
    assert normalized.autonomy["deployToStaging"]
    refute normalized.autonomy["deployToProduction"]

    assert normalized.restrictions["protectedPaths"] == [".github/", "repository-owned/"]
    assert normalized.restrictions["allowedNetworkDomains"] == ["github.com"]
    assert "platform-only-action" in normalized.restrictions["prohibitedActions"]
    assert "delete-production-data" in normalized.restrictions["prohibitedActions"]
    assert "deploy-to-production" in normalized.restrictions["prohibitedActions"]
    assert "expose-secrets" in normalized.restrictions["prohibitedActions"]
    assert "modify-billing" in normalized.restrictions["prohibitedActions"]
    assert "weaken-branch-protection" in normalized.restrictions["prohibitedActions"]

    weakened_policy = %Policy{
      allowed_autonomy: MapSet.new(["deployToProduction"]),
      prohibited_actions: MapSet.new()
    }

    assert {:ok, still_bounded} =
             ProjectManifest.validate(manifest, platform_policy: weakened_policy)

    refute still_bounded.autonomy["deployToProduction"]
    assert "deploy-to-production" in still_bounded.restrictions["prohibitedActions"]
  end

  test "repository verification settings cannot weaken mandatory platform checks" do
    weakened =
      valid_manifest()
      |> put_in(["verification", "independent"], false)
      |> put_in(["verification", "requireDeterministicChecks"], false)

    assert {:error, errors} = ProjectManifest.validate(weakened)

    assert_error(
      errors,
      :platform_policy_conflict,
      "/verification/independent",
      "requires independent"
    )

    assert_error(
      errors,
      :platform_policy_conflict,
      "/verification/requireDeterministicChecks",
      "requires requireDeterministicChecks"
    )
  end

  test "validation neither executes commands nor mutates repository-provided files" do
    directory = temporary_directory!()
    marker_path = Path.join(directory, "command-ran")
    manifest_path = Path.join(directory, "project.sxf.json")

    command =
      "elixir -e 'File.write!(#{inspect(marker_path)}, \"unexpected\")'"

    content = valid_manifest() |> put_in(["commands", "test"], command) |> Jason.encode!()
    File.write!(manifest_path, content)
    before = directory_snapshot(directory)

    assert {:ok, normalized} = ProjectManifest.load(manifest_path)
    assert normalized.commands["test"] == command
    refute File.exists?(marker_path)
    assert directory_snapshot(directory) == before
  end

  test "empty commands, duplicate restrictions, and oversized manifests fail safely" do
    invalid =
      valid_manifest()
      |> put_in(["commands", "lint"], "")
      |> Map.put("restrictions", %{"protectedPaths" => [".github/", ".github/"]})

    assert {:error, errors} = ProjectManifest.validate(invalid)
    assert_error(errors, :schema_validation, "/commands/lint")
    assert_error(errors, :schema_validation, "/restrictions/protectedPaths")

    oversized = String.duplicate("x", 1_048_577)

    assert {:error, [%Error{code: :manifest_too_large}]} =
             ProjectManifest.load_string(oversized, :yaml)
  end

  test "unsupported file extensions and invalid policy values fail clearly" do
    path = temporary_file!("project.sxf.toml", "schemaVersion = '0.1'")

    assert {:error, [%Error{code: :unsupported_format, message: message}]} =
             ProjectManifest.load(path)

    assert message =~ ".toml"

    assert {:error, [%Error{code: :invalid_platform_policy}]} =
             ProjectManifest.validate(valid_manifest(), platform_policy: :untrusted)

    assert {:error, [%Error{code: :invalid_platform_policy}]} =
             ProjectManifest.validate(valid_manifest(), platform_policy: ["not", "keyword"])
  end

  defp valid_manifest do
    %{
      "schemaVersion" => "0.1",
      "project" => %{
        "name" => "example",
        "description" => "Connected project",
        "status" => "existing"
      },
      "commands" => %{
        "install" => "mix deps.get",
        "test" => "mix test"
      },
      "autonomy" => %{
        "createBranches" => false,
        "openPullRequests" => false,
        "mergeToDefault" => false,
        "deployToProduction" => false
      },
      "verification" => %{
        "independent" => true,
        "requireDeterministicChecks" => true
      },
      "budgets" => %{
        "maxCostUsd" => 10,
        "maxRuntimeMinutes" => 60,
        "maxRepairCycles" => 2
      }
    }
  end

  defp assert_error(errors, code, path, message_fragment \\ nil) do
    assert Enum.any?(errors, fn error ->
             error.code == code and error.path == path and
               (is_nil(message_fragment) or error.message =~ message_fragment)
           end),
           "expected #{inspect(code)} at #{path}, got: #{inspect(errors)}"
  end

  defp temporary_file!(name, content) do
    directory = temporary_directory!()
    path = Path.join(directory, name)
    File.write!(path, content)
    path
  end

  defp temporary_directory! do
    path =
      Path.join(
        System.tmp_dir!(),
        "sxf-manifest-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp directory_snapshot(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Map.new(fn name ->
      path = Path.join(directory, name)
      {name, File.read!(path)}
    end)
  end
end

defmodule Sxf.ProjectManifestTest do
  use ExUnit.Case, async: true

  alias Sxf.ProjectManifest
  alias Sxf.ProjectManifest.Error
  alias Sxf.ProjectManifest.Policy

  @example_path Path.expand("../../examples/project.sxf.yaml", __DIR__)

  test "loads and normalizes the example YAML manifest within explicit platform policy" do
    assert {:ok, %ProjectManifest{} = manifest} =
             ProjectManifest.load(@example_path, platform_policy: example_policy())

    assert manifest.schema_version == "0.1"
    assert manifest.project["documentationRoot"] == "docs"
    assert manifest.commands["install"] == "npm ci"
    assert manifest.commands["test"] == "npm test"
    assert manifest.requested_autonomy["createBranches"]
    assert manifest.requested_autonomy["openPullRequests"]
    assert manifest.autonomy["createIssues"]
    assert manifest.autonomy["createBranches"]
    assert manifest.autonomy["openPullRequests"]

    assert manifest.restrictions["allowedNetworkDomains"] == [
             "github.com",
             "registry.npmjs.org"
           ]

    assert manifest.budgets["maxCostMicrousd"] == 15_000_000
    refute Map.has_key?(manifest.budgets, "maxCostUsd")
    assert "expose-secrets" in manifest.restrictions["prohibitedActions"]
  end

  test "the default platform policy rejects authority and network requests" do
    assert {:error, errors} = ProjectManifest.load(@example_path)

    assert_error(errors, :platform_policy_conflict, "/autonomy/createIssues")
    assert_error(errors, :platform_policy_conflict, "/autonomy/createBranches")
    assert_error(errors, :platform_policy_conflict, "/autonomy/openPullRequests")

    assert_error(
      errors,
      :platform_policy_conflict,
      "/restrictions/allowedNetworkDomains/0",
      "registry.npmjs.org"
    )

    assert_error(
      errors,
      :platform_policy_conflict,
      "/restrictions/allowedNetworkDomains/1",
      "github.com"
    )
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
      |> Map.put("restrictions", %{"allowedNetworkDomains" => ["github.com"]})

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

    assert {:ok, yaml_manifest} =
             ProjectManifest.load_string(yaml, :yaml, platform_policy: example_policy())

    assert {:ok, json_manifest} =
             ProjectManifest.load_string(
               Jason.encode!(decoded),
               :json,
               platform_policy: example_policy()
             )

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
      |> update_in(
        ["budgets"],
        &Map.drop(&1, ["maxCostUsd", "maxRuntimeMinutes", "maxAgentTurns"])
      )
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
    assert_error(errors, :missing_required_property, "/budgets", "maxAgentTurns")
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

  test "decoded nesting depth is bounded for JSON, YAML, and direct validation" do
    deep_json = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)

    assert {:error, [%Error{code: :maximum_nesting_depth, path: path}]} =
             ProjectManifest.load_string(deep_json, :json)

    assert String.starts_with?(path, "/")

    deep_yaml =
      0..64
      |> Enum.map_join("\n", fn depth -> String.duplicate("  ", depth) <> "level#{depth}:" end)
      |> Kernel.<>(" value\n")

    assert {:error, [%Error{code: :maximum_nesting_depth}]} =
             ProjectManifest.load_string(deep_yaml, :yaml)

    deep_term = Enum.reduce(1..65, 0, fn _index, nested -> [nested] end)

    assert {:error, [%Error{code: :maximum_nesting_depth}]} =
             ProjectManifest.validate(deep_term)

    pathological_json =
      String.duplicate("[", 100_000) <> "0" <> String.duplicate("]", 100_000)

    assert {:error, [%Error{code: code, path: pathological_path}]} =
             ProjectManifest.load_string(pathological_json, :json)

    assert code in [:maximum_nesting_depth, :decoded_structure_limit]
    assert String.starts_with?(pathological_path, "/")
  end

  test "decoded node and container counts are independently bounded" do
    too_many_nodes = "[" <> Enum.map_join(1..10_000, ",", fn _ -> "0" end) <> "]"

    assert {:error, [%Error{code: :maximum_node_count}]} =
             ProjectManifest.load_string(too_many_nodes, :json)

    too_many_containers =
      "[" <> Enum.map_join(1..2_001, ",", fn _ -> "[]" end) <> "]"

    assert {:error, [%Error{code: :maximum_container_count}]} =
             ProjectManifest.load_string(too_many_containers, :json)
  end

  test "YAML anchors and aliases are rejected before expansion" do
    for source <- ["value: &anchor explicit\n", "value: *alias\n"] do
      assert {:error,
              [
                %Error{
                  code: :yaml_references_not_allowed,
                  path: "/",
                  message: message
                }
              ]} = ProjectManifest.load_string(source, :yaml)

      assert message =~ "anchors and aliases"
    end

    quoted = ~s(project: "literal &anchor and *alias")

    assert {:error, errors} = ProjectManifest.load_string(quoted, :yaml)
    refute Enum.any?(errors, &(&1.code == :yaml_references_not_allowed))
  end

  test "repository authority and network requests outside platform ceilings fail onboarding" do
    manifest =
      valid_manifest()
      |> Map.put(
        "autonomy",
        Map.new(Policy.autonomy_keys(), &{&1, true})
      )
      |> Map.put("restrictions", %{
        "allowedNetworkDomains" => ["github.com", "exfiltration.invalid"]
      })

    policy =
      Policy.new(
        allowed_autonomy: ["createIssues", "createBranches", "openPullRequests"],
        allowed_network_domains: ["github.com"]
      )

    assert {:error, errors} = ProjectManifest.validate(manifest, platform_policy: policy)

    assert_error(errors, :platform_policy_conflict, "/autonomy/mergeToDefault")
    assert_error(errors, :platform_policy_conflict, "/autonomy/deployToStaging")
    assert_error(errors, :platform_policy_conflict, "/autonomy/deployToProduction")

    assert_error(
      errors,
      :platform_policy_conflict,
      "/restrictions/allowedNetworkDomains/1",
      "exfiltration.invalid"
    )
  end

  test "accepted repository restrictions remain additive to mandatory platform restrictions" do
    manifest =
      valid_manifest()
      |> put_in(["autonomy", "createBranches"], true)
      |> Map.put("restrictions", %{
        "protectedPaths" => ["repository-owned/"],
        "prohibitedActions" => [],
        "allowedNetworkDomains" => ["github.com"]
      })

    policy =
      Policy.new(
        allowed_autonomy: ["createBranches"],
        protected_paths: [".github/"],
        prohibited_actions: ["platform-only-action"],
        allowed_network_domains: ["github.com", "platform.internal"]
      )

    assert {:ok, normalized} = ProjectManifest.validate(manifest, platform_policy: policy)

    assert normalized.requested_autonomy["createBranches"]
    assert normalized.autonomy["createBranches"]

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

    production_request = put_in(valid_manifest(), ["autonomy", "deployToProduction"], true)

    assert {:error, errors} =
             ProjectManifest.validate(production_request, platform_policy: weakened_policy)

    assert_error(errors, :platform_policy_conflict, "/autonomy/deployToProduction")
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

  test "platform verification policy enforces every boolean gate and minimum coverage" do
    weakened =
      valid_manifest()
      |> Map.put("verification", %{
        "independent" => false,
        "requireDeterministicChecks" => false,
        "requireDifferentBackend" => false,
        "requireUiEvidence" => false,
        "minimumCoveragePercent" => 79.99
      })

    policy =
      Policy.new(
        required_verification: [
          "independent",
          "requireDeterministicChecks",
          "requireDifferentBackend",
          "requireUiEvidence"
        ],
        minimum_coverage_percent: 80
      )

    assert {:error, errors} = ProjectManifest.validate(weakened, platform_policy: policy)

    for requirement <- ~w(
          independent
          requireDeterministicChecks
          requireDifferentBackend
          requireUiEvidence
        ) do
      assert_error(
        errors,
        :platform_policy_conflict,
        "/verification/#{requirement}",
        "requires #{requirement}"
      )
    end

    assert_error(
      errors,
      :platform_policy_conflict,
      "/verification/minimumCoveragePercent",
      "at least 80"
    )

    stricter =
      put_in(weakened, ["verification"], %{
        "independent" => true,
        "requireDeterministicChecks" => true,
        "requireDifferentBackend" => true,
        "requireUiEvidence" => true,
        "minimumCoveragePercent" => 95
      })

    assert {:ok, normalized} = ProjectManifest.validate(stricter, platform_policy: policy)
    assert normalized.verification["minimumCoveragePercent"] == 95
  end

  test "every repository budget above its platform ceiling fails at the requested path" do
    manifest =
      valid_manifest()
      |> Map.put("budgets", %{
        "maxCostUsd" => 10.0000001,
        "maxRuntimeMinutes" => 61,
        "maxAgentTurns" => 41,
        "maxRepairCycles" => 3
      })

    policy =
      Policy.new(
        max_cost_microusd: 10_000_000,
        max_runtime_minutes: 60,
        max_agent_turns: 40,
        max_repair_cycles: 2
      )

    assert {:error, errors} = ProjectManifest.validate(manifest, platform_policy: policy)

    assert_error(errors, :platform_policy_conflict, "/budgets/maxCostUsd", "10000000")
    assert_error(errors, :platform_policy_conflict, "/budgets/maxRuntimeMinutes", "60")
    assert_error(errors, :platform_policy_conflict, "/budgets/maxAgentTurns", "40")
    assert_error(errors, :platform_policy_conflict, "/budgets/maxRepairCycles", "2")
  end

  test "USD budgets normalize deterministically to integer microusd without rounding upward" do
    yaml = """
    schemaVersion: "0.1"
    project: {name: exact-cost, description: exact cost, status: existing}
    commands: {install: noop, test: noop}
    autonomy:
      createBranches: false
      openPullRequests: false
      mergeToDefault: false
      deployToProduction: false
    verification: {independent: true, requireDeterministicChecks: true}
    budgets:
      maxCostUsd: 0.000001999999
      maxRuntimeMinutes: 1
      maxAgentTurns: 1
      maxRepairCycles: 0
    """

    json =
      yaml
      |> YamlElixir.read_from_string!()
      |> Jason.encode!()

    assert {:ok, yaml_manifest} = ProjectManifest.load_string(yaml, :yaml)
    assert {:ok, json_manifest} = ProjectManifest.load_string(json, :json)
    assert yaml_manifest.budgets["maxCostMicrousd"] == 1
    assert json_manifest.budgets["maxCostMicrousd"] == 1
    assert is_integer(yaml_manifest.budgets["maxCostMicrousd"])

    exact_ceiling_policy = Policy.new(max_cost_microusd: 10_000_000)
    yaml_over_ceiling = String.replace(yaml, "0.000001999999", "10.0000000000000001")

    json_over_ceiling =
      valid_manifest()
      |> Jason.encode!()
      |> String.replace(~s("maxCostUsd":10), ~s("maxCostUsd":10.0000000000000001))

    for {source, format} <- [{yaml_over_ceiling, :yaml}, {json_over_ceiling, :json}] do
      assert {:error, errors} =
               ProjectManifest.load_string(
                 source,
                 format,
                 platform_policy: exact_ceiling_policy
               )

      assert_error(errors, :platform_policy_conflict, "/budgets/maxCostUsd")
    end
  end

  test "quoted YAML numeric-looking and special cost strings remain schema errors" do
    yaml = """
    schemaVersion: "0.1"
    project: {name: quoted-cost, description: quoted cost, status: existing}
    commands: {install: noop, test: noop}
    autonomy:
      createBranches: false
      openPullRequests: false
      mergeToDefault: false
      deployToProduction: false
    verification: {independent: true, requireDeterministicChecks: true}
    budgets:
      maxCostUsd: VALUE
      maxRuntimeMinutes: 1
      maxAgentTurns: 1
      maxRepairCycles: 0
    """

    for value <- ~w(10 10.0000001 1e3 NaN Infinity) do
      source = String.replace(yaml, "VALUE", ~s("#{value}"))

      assert {:error, errors} = ProjectManifest.load_string(source, :yaml)
      assert_error(errors, :schema_validation, "/budgets/maxCostUsd")
    end

    json_manifest =
      valid_manifest()
      |> Map.put("budgets", %{
        "maxCostUsd" => 10,
        "maxRuntimeMinutes" => 60,
        "maxAgentTurns" => 40,
        "maxRepairCycles" => 2
      })
      |> Jason.encode!()

    assert {:ok, normalized} = ProjectManifest.load_string(json_manifest, :json)
    assert normalized.budgets["maxCostMicrousd"] == 10_000_000
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

    invalid_ceiling = %Policy{max_cost_microusd: 0}

    assert {:error, [%Error{code: :invalid_platform_policy}]} =
             ProjectManifest.validate(valid_manifest(), platform_policy: invalid_ceiling)
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
        "maxAgentTurns" => 40,
        "maxRepairCycles" => 2
      }
    }
  end

  defp example_policy do
    Policy.new(
      allowed_autonomy: ["createIssues", "createBranches", "openPullRequests"],
      allowed_network_domains: ["github.com", "registry.npmjs.org"]
    )
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

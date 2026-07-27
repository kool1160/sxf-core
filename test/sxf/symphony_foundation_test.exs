defmodule Sxf.SymphonyFoundationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Tracker, Workspace}
  alias SymphonyElixir.Config.Schema.Codex

  setup do
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_hooks = Application.get_env(:symphony_elixir, :host_hooks_enabled)
    original_tools = Application.get_env(:symphony_elixir, :provider_native_tools_enabled)

    on_exit(fn ->
      restore_env(:workflow_file_path, original_workflow_path)
      restore_env(:host_hooks_enabled, original_hooks)
      restore_env(:provider_native_tools_enabled, original_tools)
    end)

    :ok
  end

  test "the imported application is compiled but not an SXF runtime authority" do
    assert Code.ensure_loaded?(SymphonyElixir.Orchestrator)
    refute :symphony_elixir in Application.spec(:sxf_core, :applications)
    assert Process.whereis(SymphonyElixir.Orchestrator) == nil
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == nil
    assert Process.whereis(SymphonyElixir.WorkflowStore) == nil
  end

  test "provider-native GitHub tools are not advertised or executable by default" do
    workflow_path = temporary_workflow!(github_workflow())
    Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)
    Application.put_env(:symphony_elixir, :provider_native_tools_enabled, false)

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == SymphonyElixir.GitHub.Adapter
    assert binding.tool_specs == []

    response =
      Tracker.execute_bound_agent_tool(
        binding,
        "github_api",
        %{"method" => "POST", "path" => "/repos/kool1160/sxf-m3-scratch/issues"}
      )

    refute response["success"]
    assert response["output"] =~ "disabled or unsupported"
  end

  test "blank Codex commands remain invalid after dependency remediation" do
    changeset = Codex.changeset(%Codex{}, %{command: ""})

    refute changeset.valid?
    assert {"can't be blank", _metadata} = changeset.errors[:command]
  end

  test "repository hooks cannot execute on the host by default" do
    root = temporary_directory!()
    marker = Path.join(root, "host-hook-ran")
    workflow_path = temporary_workflow!(hook_workflow(root, marker))

    Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)
    Application.put_env(:symphony_elixir, :host_hooks_enabled, false)

    assert {:error, {:host_hooks_disabled, "after_create"}} =
             Workspace.create_for_issue("GH-17")

    refute File.exists?(marker)
  end

  defp github_workflow do
    """
    ---
    tracker:
      kind: github
      provider:
        repo: kool1160/sxf-m3-scratch
        token: test-token-not-a-credential
      active_states:
        - open
      terminal_states:
        - closed
    codex:
      command: codex app-server
    ---

    Test workflow.
    """
  end

  defp hook_workflow(root, marker) do
    """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{root}
    hooks:
      after_create: |
        printf unsafe > #{marker}
    codex:
      command: codex app-server
    ---

    Test workflow.
    """
  end

  defp temporary_workflow!(contents) do
    path = Path.join(temporary_directory!(), "WORKFLOW.md")
    File.write!(path, contents)
    path
  end

  defp temporary_directory! do
    path = Path.join(System.tmp_dir!(), "sxf-symphony-#{Ecto.UUID.generate()}")
    File.mkdir_p!(path)
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

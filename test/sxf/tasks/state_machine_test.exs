defmodule Sxf.Tasks.StateMachineTest do
  use ExUnit.Case, async: true

  alias Sxf.Tasks.StateMachine

  @expected_edges %{
    "DISCOVERED" => ~w(SPECIFIED BLOCKED FAILED CANCELLED),
    "SPECIFIED" => ~w(PLANNED BLOCKED FAILED CANCELLED),
    "PLANNED" => ~w(READY BLOCKED FAILED CANCELLED),
    "READY" => ~w(IMPLEMENTING BLOCKED FAILED CANCELLED),
    "IMPLEMENTING" => ~w(CI_RUNNING BLOCKED FAILED CANCELLED),
    "CI_RUNNING" => ~w(VERIFYING CHANGES_REQUESTED BLOCKED FAILED CANCELLED),
    "VERIFYING" => ~w(APPROVED CHANGES_REQUESTED BLOCKED FAILED CANCELLED),
    "CHANGES_REQUESTED" => ~w(IMPLEMENTING BLOCKED FAILED CANCELLED),
    "APPROVED" => ~w(STAGING CHANGES_REQUESTED BLOCKED FAILED CANCELLED),
    "STAGING" => ~w(RELEASE_READY CHANGES_REQUESTED BLOCKED FAILED CANCELLED),
    "RELEASE_READY" => ~w(DEPLOYED CHANGES_REQUESTED BLOCKED FAILED CANCELLED),
    "DEPLOYED" => [],
    "FAILED" => ~w(READY),
    "BLOCKED" =>
      ~w(DISCOVERED SPECIFIED PLANNED READY IMPLEMENTING CI_RUNNING VERIFYING CHANGES_REQUESTED APPROVED STAGING RELEASE_READY FAILED CANCELLED),
    "CANCELLED" => ~w(READY)
  }

  test "the complete legal edge set is explicit" do
    assert Map.keys(StateMachine.edges()) |> Enum.sort() ==
             Map.keys(@expected_edges) |> Enum.sort()

    for {state, expected} <- @expected_edges do
      assert MapSet.new(StateMachine.outgoing(state)) == MapSet.new(expected)
    end

    assert MapSet.new(StateMachine.incoming("DISCOVERED")) == MapSet.new([nil, "BLOCKED"])
  end

  test "every declared edge validates when its durable preconditions are present" do
    context = %{
      active_blocker?: true,
      blockers_resolved?: true,
      attempt_active?: true,
      lease_active?: true,
      budget_available?: true,
      repair_budget_available?: true,
      check_evidence?: true,
      verification_evidence?: true,
      deploy_approved?: true,
      reopen_approved?: true,
      cancellation_authorized?: true,
      terminal_failure?: true
    }

    assert :ok = StateMachine.validate(nil, "DISCOVERED", context)

    for {prior, destinations} <- @expected_edges,
        resulting <- destinations do
      assert :ok =
               StateMachine.validate(prior, resulting, Map.put(context, :resume_state, resulting)),
             "expected #{prior} -> #{resulting} to be valid"
    end
  end

  test "all undeclared state pairs are rejected" do
    for prior <- StateMachine.states(),
        resulting <- StateMachine.states(),
        resulting not in Map.fetch!(@expected_edges, prior) do
      assert {:error, :illegal_transition} = StateMachine.validate(prior, resulting, %{}),
             "expected #{prior} -> #{resulting} to be illegal"
    end
  end

  test "execution and repair transitions require an attempt, lease, and budget" do
    base = %{attempt_active?: true, lease_active?: true, budget_available?: true}

    assert :ok = StateMachine.validate("READY", "IMPLEMENTING", base)

    assert {:error, :active_attempt_required} =
             StateMachine.validate("READY", "IMPLEMENTING", %{})

    assert {:error, :repair_budget_required} =
             StateMachine.validate("CHANGES_REQUESTED", "IMPLEMENTING", base)

    assert :ok =
             StateMachine.validate(
               "CHANGES_REQUESTED",
               "IMPLEMENTING",
               Map.put(base, :repair_budget_available?, true)
             )
  end

  test "checks and independent verification require finalized evidence" do
    assert {:error, :finalized_check_evidence_required} =
             StateMachine.validate("CI_RUNNING", "VERIFYING", %{})

    assert :ok = StateMachine.validate("CI_RUNNING", "VERIFYING", %{check_evidence?: true})

    assert {:error, :finalized_verification_evidence_required} =
             StateMachine.validate("VERIFYING", "APPROVED", %{})

    assert :ok =
             StateMachine.validate("VERIFYING", "APPROVED", %{verification_evidence?: true})
  end

  test "blocking and unblocking use a saved resume state" do
    assert {:error, :active_blocker_required} =
             StateMachine.validate("IMPLEMENTING", "BLOCKED", %{})

    assert :ok =
             StateMachine.validate("IMPLEMENTING", "BLOCKED", %{active_blocker?: true})

    assert {:error, :active_blockers_remain} =
             StateMachine.validate("BLOCKED", "IMPLEMENTING", %{
               blockers_resolved?: false,
               resume_state: "IMPLEMENTING"
             })

    assert {:error, {:resume_state_mismatch, "IMPLEMENTING"}} =
             StateMachine.validate("BLOCKED", "READY", %{
               blockers_resolved?: true,
               resume_state: "IMPLEMENTING"
             })
  end

  test "terminal states have explicit reopening policy" do
    assert StateMachine.terminal?("DEPLOYED")
    assert StateMachine.terminal?("FAILED")
    assert StateMachine.terminal?("CANCELLED")
    refute StateMachine.terminal?("BLOCKED")

    assert StateMachine.outgoing("DEPLOYED") == []

    assert {:error, :reopen_approval_required} =
             StateMachine.validate("FAILED", "READY", %{budget_available?: true})

    assert :ok =
             StateMachine.validate("CANCELLED", "READY", %{
               reopen_approved?: true,
               budget_available?: true
             })
  end

  test "failure, cancellation, and deployment require explicit authority" do
    assert {:error, :terminal_failure_classification_required} =
             StateMachine.validate("READY", "FAILED", %{})

    assert {:error, :cancellation_authorization_required} =
             StateMachine.validate("READY", "CANCELLED", %{})

    assert {:error, :deploy_approval_required} =
             StateMachine.validate("RELEASE_READY", "DEPLOYED", %{})
  end
end

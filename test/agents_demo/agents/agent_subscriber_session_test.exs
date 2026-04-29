defmodule AgentsDemo.Agents.AgentSubscriberSessionTest do
  use ExUnit.Case, async: true

  alias AgentsDemo.Agents.AgentSubscriberSession

  describe "init_session_state/0" do
    test "starts with agent_status :not_running so the Wake button is shown for empty state" do
      state = AgentSubscriberSession.init_session_state()
      assert state.agent_status == :not_running
      assert state.agent_id == nil
    end
  end

  describe "handle_agent_shutdown/2" do
    test "flips agent_status to :not_running so the Wake button reappears" do
      state = %{
        agent_id: "conversation-1",
        agent_status: :idle,
        loading: true,
        streaming_delta: %{},
        sagents_subs: %{}
      }

      changes = AgentSubscriberSession.handle_agent_shutdown(state, %{reason: :inactivity})

      assert changes.agent_status == :not_running
      assert changes.agent_id == nil
      assert changes.loading == false
      assert changes.streaming_delta == nil
    end

    test "still clears status when there's no current agent_id" do
      state = %{agent_id: nil, agent_status: :idle, sagents_subs: %{}}

      changes = AgentSubscriberSession.handle_agent_shutdown(state, %{reason: :no_viewers})

      assert changes.agent_status == :not_running
      assert changes.agent_id == nil
      assert changes.loading == false
      assert changes.streaming_delta == nil
    end
  end
end

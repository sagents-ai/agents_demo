defmodule AgentsDemo.Agents.AgentPersistenceTest do
  use AgentsDemo.DataCase

  import AgentsDemo.AccountsFixtures
  import AgentsDemo.ConversationsFixtures
  import ExUnit.CaptureLog

  alias AgentsDemo.Agents.AgentPersistence
  alias AgentsDemo.Conversations

  describe "persist_state/3" do
    test "persists state for an existing conversation" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      agent_id = "conversation-#{conversation.id}"
      state_data = %{"version" => 1, "messages" => []}

      context = %{
        agent_id: agent_id,
        conversation_id: conversation.id,
        lifecycle: :on_completion
      }

      assert :ok = AgentPersistence.persist_state(scope, state_data, context)
      assert {:ok, ^state_data} = Conversations.load_agent_state(scope, conversation.id)
    end

    test "returns :ok and logs a warning when the conversation was deleted" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(scope: scope)
      agent_id = "conversation-#{conversation.id}"
      state_data = %{"version" => 1, "messages" => []}

      {:ok, _} = Conversations.delete_conversation(scope, conversation.id)

      context = %{
        agent_id: agent_id,
        conversation_id: conversation.id,
        lifecycle: :on_shutdown
      }

      log =
        capture_log(fn ->
          assert :ok = AgentPersistence.persist_state(scope, state_data, context)
        end)

      assert log =~ "Skipping agent state persistence"
      assert log =~ agent_id
      # After scope check fires first, the log message differs based on whether
      # the conversation was accessible in scope. Either form is acceptable here:
      assert log =~ "conversation no longer exists" or
               log =~ "conversation not accessible in scope"
    end
  end
end

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

    test "does not touch the interrupt flag" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      {:ok, _} = Conversations.set_interrupt_status(scope, conversation.id, true)

      context = %{
        agent_id: "conversation-#{conversation.id}",
        conversation_id: conversation.id,
        lifecycle: :on_completion
      }

      assert :ok = AgentPersistence.persist_state(scope, %{"version" => 1}, context)

      reloaded = Conversations.get_conversation!(scope, conversation.id)
      # persist_state is not in charge of the durable flag — sagents drives
      # transitions via set_interrupted/3. The flag must remain untouched.
      assert reloaded.metadata["interrupted"] == true
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

  describe "set_interrupted/3" do
    setup do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      context = %{
        agent_id: "conversation-#{conversation.id}",
        conversation_id: conversation.id
      }

      %{scope: scope, conversation: conversation, context: context}
    end

    test "writes true to conversation.metadata['interrupted']", %{
      scope: scope,
      conversation: conversation,
      context: context
    } do
      assert :ok = AgentPersistence.set_interrupted(scope, context, true)

      reloaded = Conversations.get_conversation!(scope, conversation.id)
      assert reloaded.metadata["interrupted"] == true
    end

    test "writes false to clear an existing flag", %{
      scope: scope,
      conversation: conversation,
      context: context
    } do
      {:ok, _} = Conversations.set_interrupt_status(scope, conversation.id, true)

      assert :ok = AgentPersistence.set_interrupted(scope, context, false)

      reloaded = Conversations.get_conversation!(scope, conversation.id)
      assert reloaded.metadata["interrupted"] == false
    end

    test "returns :ok and logs a warning when the conversation no longer exists", %{
      scope: scope,
      conversation: conversation,
      context: context
    } do
      {:ok, _} = Conversations.delete_conversation(scope, conversation.id)

      log =
        capture_log(fn ->
          assert :ok = AgentPersistence.set_interrupted(scope, context, true)
        end)

      assert log =~ "Skipping interrupt flag update"
      assert log =~ context.agent_id
    end
  end
end

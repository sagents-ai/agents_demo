defmodule AgentsDemo.ConversationsTest do
  use AgentsDemo.DataCase

  alias AgentsDemo.Conversations
  alias AgentsDemo.Conversations.{Conversation, AgentState, DisplayMessage}

  import AgentsDemo.AccountsFixtures
  import AgentsDemo.ConversationsFixtures

  describe "create_conversation/2" do
    test "creates a conversation with valid attributes" do
      scope = user_scope_fixture()

      attrs = %{
        title: "My Conversation",
        metadata: %{"agent_id" => "agent-001"}
      }

      assert {:ok, %Conversation{} = conversation} =
               Conversations.create_conversation(scope, attrs)

      assert conversation.title == "My Conversation"
      assert conversation.metadata == %{"agent_id" => "agent-001"}
      assert conversation.user_id == scope.user.id
      assert conversation.version == 1
    end

    test "creates conversation with minimal attributes" do
      scope = user_scope_fixture()

      assert {:ok, %Conversation{} = conversation} =
               Conversations.create_conversation(scope, %{})

      assert conversation.user_id == scope.user.id
      assert is_nil(conversation.title)
      assert conversation.metadata == %{}
    end
  end

  describe "get_conversation!/2" do
    test "returns the conversation when it exists and belongs to scope" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert fetched = Conversations.get_conversation!(scope, conversation.id)
      assert fetched.id == conversation.id
      assert fetched.title == conversation.title
    end

    test "raises when conversation doesn't exist" do
      scope = user_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(scope, Ecto.UUID.generate())
      end
    end

    test "raises when conversation belongs to different user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      conversation = conversation_fixture(%{scope: scope1})

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(scope2, conversation.id)
      end
    end
  end

  describe "list_conversations/2" do
    test "returns conversations scoped to user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      conv1 = conversation_fixture(%{scope: scope1, title: "Conversation 1"})
      conv2 = conversation_fixture(%{scope: scope1, title: "Conversation 2"})
      _conv3 = conversation_fixture(%{scope: scope2, title: "Other User"})

      conversations = Conversations.list_conversations(scope1)

      assert length(conversations) == 2
      assert Enum.any?(conversations, &(&1.id == conv1.id))
      assert Enum.any?(conversations, &(&1.id == conv2.id))
    end

    test "orders conversations by updated_at DESC" do
      scope = user_scope_fixture()

      conv1 = conversation_fixture(%{scope: scope, title: "First"})
      :timer.sleep(10)
      conv2 = conversation_fixture(%{scope: scope, title: "Second"})
      :timer.sleep(10)
      conv3 = conversation_fixture(%{scope: scope, title: "Third"})

      conversations = Conversations.list_conversations(scope)

      assert Enum.at(conversations, 0).id == conv3.id
      assert Enum.at(conversations, 1).id == conv2.id
      assert Enum.at(conversations, 2).id == conv1.id
    end

    test "respects limit option" do
      scope = user_scope_fixture()

      for i <- 1..10 do
        conversation_fixture(%{scope: scope, title: "Conversation #{i}"})
      end

      conversations = Conversations.list_conversations(scope, limit: 5)
      assert length(conversations) == 5
    end

    test "respects offset option" do
      scope = user_scope_fixture()

      for i <- 1..10 do
        conversation_fixture(%{scope: scope, title: "Conversation #{i}"})
      end

      all_conversations = Conversations.list_conversations(scope, limit: 100)
      offset_conversations = Conversations.list_conversations(scope, limit: 5, offset: 5)

      assert length(offset_conversations) == 5
      assert Enum.at(offset_conversations, 0).id == Enum.at(all_conversations, 5).id
    end
  end

  describe "update_conversation/2" do
    test "updates conversation with valid attributes" do
      conversation = conversation_fixture(%{title: "Original"})

      assert {:ok, updated} =
               Conversations.update_conversation(conversation, %{title: "Updated"})

      assert updated.title == "Updated"
      assert updated.id == conversation.id
    end

    test "updates metadata" do
      conversation = conversation_fixture(%{metadata: %{"key" => "value"}})

      assert {:ok, updated} =
               Conversations.update_conversation(conversation, %{
                 metadata: %{"key" => "new_value", "new_key" => "data"}
               })

      assert updated.metadata == %{"key" => "new_value", "new_key" => "data"}
    end
  end

  describe "delete_conversation/1" do
    test "deletes the conversation" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:ok, deleted} = Conversations.delete_conversation(conversation)
      assert deleted.id == conversation.id

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(scope, conversation.id)
      end
    end

    test "deletes associated agent state" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      agent_state_fixture(scope, conversation.id)

      assert {:ok, _} = Conversations.delete_conversation(conversation)

      # Agent state should be deleted due to on_delete: :delete_all
      assert {:error, :not_found} = Conversations.load_agent_state(scope, conversation.id)
    end

    test "deletes associated display messages" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      text_message_fixture(scope, conversation.id, %{text: "Message 1"})
      text_message_fixture(scope, conversation.id, %{text: "Message 2"})

      assert {:ok, _} = Conversations.delete_conversation(conversation)

      # `load_display_messages` returns [] when conversation is missing in scope.
      assert [] = Conversations.load_display_messages(scope, conversation.id)
    end
  end

  describe "save_agent_state/3 and load_agent_state/2" do
    test "saves agent state for new conversation" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      state_data = %{
        "version" => 1,
        "agent_id" => "test-agent",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      }

      assert {:ok, %AgentState{} = agent_state} =
               Conversations.save_agent_state(scope, conversation.id, state_data)

      assert agent_state.conversation_id == conversation.id
      assert agent_state.state_data == state_data
      assert agent_state.version == 1
    end

    test "updates existing agent state" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      state_v1 = %{"version" => 1, "agent_id" => "test", "messages" => []}
      state_v2 = %{"version" => 2, "agent_id" => "test", "messages" => [%{"new" => "data"}]}

      assert {:ok, initial} = Conversations.save_agent_state(scope, conversation.id, state_v1)
      assert {:ok, updated} = Conversations.save_agent_state(scope, conversation.id, state_v2)

      # Should be the same record, just updated
      assert initial.id == updated.id
      assert updated.state_data == state_v2
      assert updated.version == 2
    end

    test "loads agent state successfully" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      state_data = %{"version" => 1, "data" => "test"}

      {:ok, _} = Conversations.save_agent_state(scope, conversation.id, state_data)

      assert {:ok, loaded_state} = Conversations.load_agent_state(scope, conversation.id)
      assert loaded_state == state_data
    end

    test "returns error when no agent state exists" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:error, :not_found} = Conversations.load_agent_state(scope, conversation.id)
    end

    test "wrong-scope save returns :not_found without writing" do
      owner_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: owner_scope})

      state_data = %{"version" => 1, "messages" => []}

      assert {:error, :not_found} =
               Conversations.save_agent_state(other_scope, conversation.id, state_data)

      # Confirm no state was persisted under the owner
      assert {:error, :not_found} = Conversations.load_agent_state(owner_scope, conversation.id)
    end

    test "wrong-scope load returns :not_found even when state exists" do
      owner_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: owner_scope})
      {:ok, _} = Conversations.save_agent_state(owner_scope, conversation.id, %{"v" => 1})

      assert {:error, :not_found} = Conversations.load_agent_state(other_scope, conversation.id)
    end
  end

  describe "set_interrupt_status/3 and interrupted?/1" do
    test "set_interrupt_status writes the boolean flag to conversation.metadata" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:ok, updated} = Conversations.set_interrupt_status(scope, conversation.id, true)
      assert updated.metadata["interrupted"] == true

      assert {:ok, cleared} = Conversations.set_interrupt_status(scope, conversation.id, false)
      assert cleared.metadata["interrupted"] == false
    end

    test "set_interrupt_status preserves existing metadata keys" do
      scope = user_scope_fixture()

      conversation =
        conversation_fixture(%{
          scope: scope,
          metadata: %{"agent_id" => "agent-001", "tag" => "important"}
        })

      assert {:ok, updated} = Conversations.set_interrupt_status(scope, conversation.id, true)

      assert updated.metadata == %{
               "agent_id" => "agent-001",
               "tag" => "important",
               "interrupted" => true
             }
    end

    test "set_interrupt_status returns :not_found for wrong-scope callers" do
      owner_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: owner_scope})

      assert {:error, :not_found} =
               Conversations.set_interrupt_status(other_scope, conversation.id, true)
    end

    test "interrupted?/1 returns true only when the flag is set to true" do
      assert Conversations.interrupted?(%Conversation{metadata: %{"interrupted" => true}}) ==
               true

      assert Conversations.interrupted?(%Conversation{metadata: %{"interrupted" => false}}) ==
               false

      assert Conversations.interrupted?(%Conversation{metadata: %{}}) == false
      assert Conversations.interrupted?(%Conversation{metadata: nil}) == false
      assert Conversations.interrupted?(nil) == false
    end
  end

  describe "append_display_message/3" do
    test "creates a display message with valid attributes" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "Hello"},
        sequence: 0,
        metadata: %{"source" => "test"}
      }

      assert {:ok, %DisplayMessage{} = message} =
               Conversations.append_display_message(scope, conversation.id, attrs)

      assert message.conversation_id == conversation.id
      assert message.message_type == "user"
      assert message.content_type == "text"
      assert message.content == %{"text" => "Hello"}
      assert message.sequence == 0
      assert message.metadata == %{"source" => "test"}
    end

    test "validates required fields" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:error, changeset} =
               Conversations.append_display_message(scope, conversation.id, %{})

      assert %{
               message_type: ["can't be blank"],
               content: ["can't be blank"],
               content_type: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates content_type inclusion" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "user",
        content_type: "invalid_type",
        content: %{"text" => "test"}
      }

      assert {:error, changeset} =
               Conversations.append_display_message(scope, conversation.id, attrs)

      assert "is invalid" in errors_on(changeset).content_type
    end

    test "validates content structure for text type" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      # Valid text content
      assert {:ok, _} =
               Conversations.append_display_message(scope, conversation.id, %{
                 message_type: "user",
                 content_type: "text",
                 content: %{"text" => "Hello"}
               })

      # Invalid text content (missing "text" key)
      assert {:error, changeset} =
               Conversations.append_display_message(scope, conversation.id, %{
                 message_type: "user",
                 content_type: "text",
                 content: %{"wrong_key" => "Hello"}
               })

      assert "invalid structure for content_type text" in errors_on(changeset).content
    end

    test "defaults sequence to 0 when not provided" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "Hello"}
      }

      assert {:ok, message} =
               Conversations.append_display_message(scope, conversation.id, attrs)

      assert message.sequence == 0
    end

    test "validates sequence is non-negative" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "Hello"},
        sequence: -1
      }

      assert {:error, changeset} =
               Conversations.append_display_message(scope, conversation.id, attrs)

      assert "must be greater than or equal to 0" in errors_on(changeset).sequence
    end

    test "wrong-scope caller receives :not_found and no row is inserted" do
      owner_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: owner_scope})

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "intruder"}
      }

      assert {:error, :not_found} =
               Conversations.append_display_message(other_scope, conversation.id, attrs)

      assert [] = Conversations.load_display_messages(owner_scope, conversation.id)
    end

    test "accepts a valid todo_snapshot content type" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      content = %{
        "todos" => [
          %{"id" => "1", "content" => "Plan", "status" => "completed"},
          %{"id" => "2", "content" => "Execute", "status" => "in_progress"},
          %{"id" => "3", "content" => "Verify", "status" => "pending"}
        ],
        "summary" => %{
          "total" => 3,
          "pending" => 1,
          "in_progress" => 1,
          "completed" => 1
        }
      }

      assert {:ok, %DisplayMessage{} = message} =
               Conversations.append_display_message(scope, conversation.id, %{
                 message_type: "system",
                 content_type: "todo_snapshot",
                 content: content
               })

      assert message.content_type == "todo_snapshot"
      assert message.content["todos"] == content["todos"]
      assert DisplayMessage.to_text(message) =~ "1 pending"
      assert DisplayMessage.to_text(message) =~ "1 completed"
    end

    test "accepts a todo_snapshot with an empty todo list (auto-clear case)" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:ok, %DisplayMessage{}} =
               Conversations.append_display_message(scope, conversation.id, %{
                 message_type: "system",
                 content_type: "todo_snapshot",
                 content: %{
                   "todos" => [],
                   "summary" => %{
                     "total" => 0,
                     "pending" => 0,
                     "in_progress" => 0,
                     "completed" => 0
                   }
                 }
               })
    end

    test "rejects a todo_snapshot missing the todos list" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:error, changeset} =
               Conversations.append_display_message(scope, conversation.id, %{
                 message_type: "system",
                 content_type: "todo_snapshot",
                 content: %{"summary" => %{"total" => 0}}
               })

      assert "invalid structure for content_type todo_snapshot" in errors_on(changeset).content
    end

    test "rejects a todo_snapshot with an invalid status value" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:error, changeset} =
               Conversations.append_display_message(scope, conversation.id, %{
                 message_type: "system",
                 content_type: "todo_snapshot",
                 content: %{
                   "todos" => [
                     %{"id" => "1", "content" => "Bad", "status" => "not_a_status"}
                   ]
                 }
               })

      assert "todo_snapshot has invalid todo entries" in errors_on(changeset).content
    end
  end

  describe "load_display_messages/3" do
    test "loads messages ordered by inserted_at and sequence" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      msg1 = text_message_fixture(scope, conversation.id, %{text: "User: Hello", sequence: 0})

      msg2 =
        thinking_message_fixture(scope, conversation.id, %{text: "Let me think...", sequence: 0})

      msg3 =
        text_message_fixture(scope, conversation.id, %{
          text: "Assistant: Response",
          message_type: "assistant",
          sequence: 1
        })

      messages = Conversations.load_display_messages(scope, conversation.id)

      assert length(messages) == 3
      assert Enum.at(messages, 0).id == msg1.id
      assert Enum.at(messages, 1).id == msg2.id
      assert Enum.at(messages, 2).id == msg3.id
    end

    test "returns empty list for conversation with no messages" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert [] = Conversations.load_display_messages(scope, conversation.id)
    end

    test "respects limit option" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      for i <- 1..10 do
        text_message_fixture(scope, conversation.id, %{text: "Message #{i}"})
      end

      messages = Conversations.load_display_messages(scope, conversation.id, limit: 5)
      assert length(messages) == 5
    end

    test "respects offset option" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      for i <- 1..10 do
        text_message_fixture(scope, conversation.id, %{text: "Message #{i}"})
      end

      all_messages = Conversations.load_display_messages(scope, conversation.id, limit: 100)

      offset_messages =
        Conversations.load_display_messages(scope, conversation.id, limit: 5, offset: 5)

      assert length(offset_messages) == 5
      assert Enum.at(offset_messages, 0).id == Enum.at(all_messages, 5).id
    end

    test "wrong-scope caller receives []" do
      owner_scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: owner_scope})
      text_message_fixture(owner_scope, conversation.id, %{text: "owner-only"})

      assert [] = Conversations.load_display_messages(other_scope, conversation.id)
    end
  end

  describe "append_text_message/4" do
    test "creates a text message for user" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:ok, message} =
               Conversations.append_text_message(scope, conversation.id, "user", "Hello there!")

      assert message.message_type == "user"
      assert message.content_type == "text"
      assert message.content == %{"text" => "Hello there!"}
      assert message.sequence == 0
    end

    test "creates a text message for assistant" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      assert {:ok, message} =
               Conversations.append_text_message(scope, conversation.id, "assistant", "Hi!")

      assert message.message_type == "assistant"
      assert message.content_type == "text"
      assert message.content == %{"text" => "Hi!"}
    end
  end

  describe "search_messages/2" do
    test "finds messages containing search term" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      text_message_fixture(scope, conversation.id, %{text: "Hello world"})
      text_message_fixture(scope, conversation.id, %{text: "Testing search functionality"})
      text_message_fixture(scope, conversation.id, %{text: "Another message"})

      results = Conversations.search_messages(scope, "search")

      assert length(results) == 1
      assert Enum.at(results, 0).content["text"] == "Testing search functionality"
    end

    test "is case insensitive" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      text_message_fixture(scope, conversation.id, %{text: "Testing SEARCH"})

      results = Conversations.search_messages(scope, "search")
      assert length(results) == 1
    end

    test "only searches within user's scope" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      conv1 = conversation_fixture(%{scope: scope1})
      conv2 = conversation_fixture(%{scope: scope2})

      text_message_fixture(scope1, conv1.id, %{text: "findme in user1"})
      text_message_fixture(scope2, conv2.id, %{text: "findme in user2"})

      results1 = Conversations.search_messages(scope1, "findme")
      assert length(results1) == 1
      assert Enum.at(results1, 0).conversation_id == conv1.id

      results2 = Conversations.search_messages(scope2, "findme")
      assert length(results2) == 1
      assert Enum.at(results2, 0).conversation_id == conv2.id
    end
  end

  describe "sequence ordering in multi-part messages" do
    test "correctly orders thinking + text + image with same timestamp" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      thinking =
        thinking_message_fixture(scope, conversation.id, %{text: "Analyzing...", sequence: 0})

      text =
        text_message_fixture(scope, conversation.id, %{
          text: "Here's the result",
          message_type: "assistant",
          sequence: 1
        })

      image = image_message_fixture(scope, conversation.id, %{url: "/chart.png", sequence: 2})

      messages = Conversations.load_display_messages(scope, conversation.id)

      assert length(messages) == 3
      assert Enum.at(messages, 0).id == thinking.id
      assert Enum.at(messages, 1).id == text.id
      assert Enum.at(messages, 2).id == image.id
    end

    test "sequence resets for each message group" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      msg1 = text_message_fixture(scope, conversation.id, %{text: "User question", sequence: 0})

      :timer.sleep(10)
      msg2 = thinking_message_fixture(scope, conversation.id, %{text: "Thinking", sequence: 0})

      msg3 =
        text_message_fixture(scope, conversation.id, %{
          text: "Response",
          message_type: "assistant",
          sequence: 1
        })

      :timer.sleep(10)
      msg4 = text_message_fixture(scope, conversation.id, %{text: "Follow-up", sequence: 0})

      messages = Conversations.load_display_messages(scope, conversation.id)

      assert length(messages) == 4
      assert Enum.at(messages, 0).id == msg1.id
      assert Enum.at(messages, 0).sequence == 0

      assert Enum.at(messages, 1).id == msg2.id
      assert Enum.at(messages, 1).sequence == 0

      assert Enum.at(messages, 2).id == msg3.id
      assert Enum.at(messages, 2).sequence == 1

      assert Enum.at(messages, 3).id == msg4.id
      assert Enum.at(messages, 3).sequence == 0
    end
  end
end

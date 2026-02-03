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

      # Create conversations with slight delays to ensure different timestamps
      conv1 = conversation_fixture(%{scope: scope, title: "First"})
      :timer.sleep(10)
      conv2 = conversation_fixture(%{scope: scope, title: "Second"})
      :timer.sleep(10)
      conv3 = conversation_fixture(%{scope: scope, title: "Third"})

      conversations = Conversations.list_conversations(scope)

      # Most recent first
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
      # Should get the 6th through 10th conversations
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
      conversation = conversation_fixture()
      agent_state_fixture(conversation.id)

      assert {:ok, _} = Conversations.delete_conversation(conversation)

      # Agent state should be deleted due to on_delete: :delete_all
      assert {:error, :not_found} = Conversations.load_agent_state(conversation.id)
    end

    test "deletes associated display messages" do
      conversation = conversation_fixture()
      text_message_fixture(conversation.id, %{text: "Message 1"})
      text_message_fixture(conversation.id, %{text: "Message 2"})

      assert {:ok, _} = Conversations.delete_conversation(conversation)

      # Messages should be deleted due to on_delete: :delete_all
      assert [] = Conversations.load_display_messages(conversation.id)
    end
  end

  describe "save_agent_state/2 and load_agent_state/1" do
    test "saves agent state for new conversation" do
      conversation = conversation_fixture()

      state_data = %{
        "version" => 1,
        "agent_id" => "test-agent",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      }

      assert {:ok, %AgentState{} = agent_state} =
               Conversations.save_agent_state(conversation.id, state_data)

      assert agent_state.conversation_id == conversation.id
      assert agent_state.state_data == state_data
      assert agent_state.version == 1
    end

    test "updates existing agent state" do
      conversation = conversation_fixture()

      state_v1 = %{"version" => 1, "agent_id" => "test", "messages" => []}
      state_v2 = %{"version" => 2, "agent_id" => "test", "messages" => [%{"new" => "data"}]}

      assert {:ok, initial} = Conversations.save_agent_state(conversation.id, state_v1)
      assert {:ok, updated} = Conversations.save_agent_state(conversation.id, state_v2)

      # Should be the same record, just updated
      assert initial.id == updated.id
      assert updated.state_data == state_v2
      assert updated.version == 2
    end

    test "loads agent state successfully" do
      conversation = conversation_fixture()
      state_data = %{"version" => 1, "data" => "test"}

      {:ok, _} = Conversations.save_agent_state(conversation.id, state_data)

      assert {:ok, loaded_state} = Conversations.load_agent_state(conversation.id)
      assert loaded_state == state_data
    end

    test "returns error when no agent state exists" do
      conversation = conversation_fixture()

      assert {:error, :not_found} = Conversations.load_agent_state(conversation.id)
    end
  end

  describe "append_display_message/2" do
    test "creates a display message with valid attributes" do
      conversation = conversation_fixture()

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "Hello"},
        sequence: 0,
        metadata: %{"source" => "test"}
      }

      assert {:ok, %DisplayMessage{} = message} =
               Conversations.append_display_message(conversation.id, attrs)

      assert message.conversation_id == conversation.id
      assert message.message_type == "user"
      assert message.content_type == "text"
      assert message.content == %{"text" => "Hello"}
      assert message.sequence == 0
      assert message.metadata == %{"source" => "test"}
    end

    test "validates required fields" do
      conversation = conversation_fixture()

      assert {:error, changeset} = Conversations.append_display_message(conversation.id, %{})

      assert %{
               message_type: ["can't be blank"],
               content: ["can't be blank"],
               content_type: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates content_type inclusion" do
      conversation = conversation_fixture()

      attrs = %{
        message_type: "user",
        content_type: "invalid_type",
        content: %{"text" => "test"}
      }

      assert {:error, changeset} = Conversations.append_display_message(conversation.id, attrs)
      assert "is invalid" in errors_on(changeset).content_type
    end

    test "validates content structure for text type" do
      conversation = conversation_fixture()

      # Valid text content
      assert {:ok, _} =
               Conversations.append_display_message(conversation.id, %{
                 message_type: "user",
                 content_type: "text",
                 content: %{"text" => "Hello"}
               })

      # Invalid text content (missing "text" key)
      assert {:error, changeset} =
               Conversations.append_display_message(conversation.id, %{
                 message_type: "user",
                 content_type: "text",
                 content: %{"wrong_key" => "Hello"}
               })

      assert "invalid structure for content_type text" in errors_on(changeset).content
    end

    test "defaults sequence to 0 when not provided" do
      conversation = conversation_fixture()

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "Hello"}
      }

      assert {:ok, message} = Conversations.append_display_message(conversation.id, attrs)
      assert message.sequence == 0
    end

    test "validates sequence is non-negative" do
      conversation = conversation_fixture()

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "Hello"},
        sequence: -1
      }

      assert {:error, changeset} = Conversations.append_display_message(conversation.id, attrs)
      assert "must be greater than or equal to 0" in errors_on(changeset).sequence
    end
  end

  describe "load_display_messages/2" do
    test "loads messages ordered by inserted_at and sequence" do
      conversation = conversation_fixture()

      # User message
      msg1 = text_message_fixture(conversation.id, %{text: "User: Hello", sequence: 0})

      # Simulate multi-part assistant response (thinking + text)
      msg2 = thinking_message_fixture(conversation.id, %{text: "Let me think...", sequence: 0})

      msg3 =
        text_message_fixture(conversation.id, %{
          text: "Assistant: Response",
          message_type: "assistant",
          sequence: 1
        })

      messages = Conversations.load_display_messages(conversation.id)

      assert length(messages) == 3

      # Should be ordered by inserted_at first, then sequence
      assert Enum.at(messages, 0).id == msg1.id
      assert Enum.at(messages, 1).id == msg2.id
      assert Enum.at(messages, 2).id == msg3.id
    end

    test "returns empty list for conversation with no messages" do
      conversation = conversation_fixture()

      assert [] = Conversations.load_display_messages(conversation.id)
    end

    test "respects limit option" do
      conversation = conversation_fixture()

      for i <- 1..10 do
        text_message_fixture(conversation.id, %{text: "Message #{i}"})
      end

      messages = Conversations.load_display_messages(conversation.id, limit: 5)
      assert length(messages) == 5
    end

    test "respects offset option" do
      conversation = conversation_fixture()

      for i <- 1..10 do
        text_message_fixture(conversation.id, %{text: "Message #{i}"})
      end

      all_messages = Conversations.load_display_messages(conversation.id, limit: 100)
      offset_messages = Conversations.load_display_messages(conversation.id, limit: 5, offset: 5)

      assert length(offset_messages) == 5
      assert Enum.at(offset_messages, 0).id == Enum.at(all_messages, 5).id
    end
  end

  describe "append_text_message/3" do
    test "creates a text message for user" do
      conversation = conversation_fixture()

      assert {:ok, message} =
               Conversations.append_text_message(conversation.id, "user", "Hello there!")

      assert message.message_type == "user"
      assert message.content_type == "text"
      assert message.content == %{"text" => "Hello there!"}
      assert message.sequence == 0
    end

    test "creates a text message for assistant" do
      conversation = conversation_fixture()

      assert {:ok, message} =
               Conversations.append_text_message(conversation.id, "assistant", "Hi!")

      assert message.message_type == "assistant"
      assert message.content_type == "text"
      assert message.content == %{"text" => "Hi!"}
    end
  end

  describe "search_messages/2" do
    test "finds messages containing search term" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      text_message_fixture(conversation.id, %{text: "Hello world"})
      text_message_fixture(conversation.id, %{text: "Testing search functionality"})
      text_message_fixture(conversation.id, %{text: "Another message"})

      results = Conversations.search_messages(scope, "search")

      assert length(results) == 1
      assert Enum.at(results, 0).content["text"] == "Testing search functionality"
    end

    test "is case insensitive" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      text_message_fixture(conversation.id, %{text: "Testing SEARCH"})

      results = Conversations.search_messages(scope, "search")
      assert length(results) == 1
    end

    test "only searches within user's scope" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()

      conv1 = conversation_fixture(%{scope: scope1})
      conv2 = conversation_fixture(%{scope: scope2})

      text_message_fixture(conv1.id, %{text: "findme in user1"})
      text_message_fixture(conv2.id, %{text: "findme in user2"})

      # scope1 should only find their message
      results1 = Conversations.search_messages(scope1, "findme")
      assert length(results1) == 1
      assert Enum.at(results1, 0).conversation_id == conv1.id

      # scope2 should only find their message
      results2 = Conversations.search_messages(scope2, "findme")
      assert length(results2) == 1
      assert Enum.at(results2, 0).conversation_id == conv2.id
    end
  end

  describe "sequence ordering in multi-part messages" do
    test "correctly orders thinking + text + image with same timestamp" do
      conversation = conversation_fixture()

      # Simulate a multi-part assistant response arriving at nearly the same time
      # In real usage, these would all be created within microseconds

      thinking = thinking_message_fixture(conversation.id, %{text: "Analyzing...", sequence: 0})

      text =
        text_message_fixture(conversation.id, %{
          text: "Here's the result",
          message_type: "assistant",
          sequence: 1
        })

      image = image_message_fixture(conversation.id, %{url: "/chart.png", sequence: 2})

      messages = Conversations.load_display_messages(conversation.id)

      # Verify order: thinking, text, image
      assert length(messages) == 3
      assert Enum.at(messages, 0).id == thinking.id
      assert Enum.at(messages, 1).id == text.id
      assert Enum.at(messages, 2).id == image.id
    end

    test "sequence resets for each message group" do
      conversation = conversation_fixture()

      # First message group (user)
      msg1 = text_message_fixture(conversation.id, %{text: "User question", sequence: 0})

      # Second message group (assistant multi-part)
      # Ensure different timestamp
      :timer.sleep(10)
      msg2 = thinking_message_fixture(conversation.id, %{text: "Thinking", sequence: 0})

      msg3 =
        text_message_fixture(conversation.id, %{
          text: "Response",
          message_type: "assistant",
          sequence: 1
        })

      # Third message group (user)
      # Ensure different timestamp
      :timer.sleep(10)
      msg4 = text_message_fixture(conversation.id, %{text: "Follow-up", sequence: 0})

      messages = Conversations.load_display_messages(conversation.id)

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

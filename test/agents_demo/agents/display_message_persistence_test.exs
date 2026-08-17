defmodule AgentsDemo.Agents.DisplayMessagePersistenceTest do
  use AgentsDemo.DataCase

  alias AgentsDemo.Agents.DisplayMessagePersistence
  alias AgentsDemo.Conversations
  alias AgentsDemo.Conversations.DisplayMessage
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult

  import AgentsDemo.AccountsFixtures
  import AgentsDemo.ConversationsFixtures

  describe "save_synthetic_message/3" do
    test "persists a user-typed answer to a question" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "PostgreSQL"}
      }

      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      assert {:ok, %DisplayMessage{} = msg} =
               DisplayMessagePersistence.save_synthetic_message(scope, attrs, context)

      assert msg.message_type == "user"
      assert msg.content_type == "text"
      assert msg.content == %{"text" => "PostgreSQL"}

      [persisted] = Conversations.load_display_messages(scope, conversation.id)
      assert persisted.id == msg.id
    end

    test "persists a cancellation as a notification message" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "system",
        content_type: "notification",
        content: %{"text" => "User cancelled"}
      }

      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      assert {:ok, %DisplayMessage{} = msg} =
               DisplayMessagePersistence.save_synthetic_message(scope, attrs, context)

      assert msg.message_type == "system"
      assert msg.content_type == "notification"
      assert msg.content == %{"text" => "User cancelled"}
    end

    test "errors out when no conversation_id is set" do
      scope = user_scope_fixture()

      assert {:error, :no_conversation} =
               DisplayMessagePersistence.save_synthetic_message(
                 scope,
                 %{
                   message_type: "user",
                   content_type: "text",
                   content: %{"text" => "x"}
                 },
                 %{agent_id: "no-conv", conversation_id: nil}
               )
    end

    test "carries metadata when provided" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})

      attrs = %{
        message_type: "user",
        content_type: "text",
        content: %{"text" => "yes"},
        metadata: %{"source" => "ask_user", "tool_call_id" => "call_42"}
      }

      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      assert {:ok, %DisplayMessage{} = msg} =
               DisplayMessagePersistence.save_synthetic_message(scope, attrs, context)

      assert msg.metadata == %{"source" => "ask_user", "tool_call_id" => "call_42"}
    end
  end

  describe "save_message/3 tool_call_id denormalization" do
    test "copies content[\"call_id\"] into the tool_call_id column for tool_call rows" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message =
        Message.new_assistant!(%{
          tool_calls: [
            ToolCall.new!(%{call_id: "call_abc", name: "search", arguments: %{"q" => "elixir"}})
          ]
        })

      assert {:ok, [%DisplayMessage{} = msg]} =
               DisplayMessagePersistence.save_message(scope, message, context)

      assert msg.content_type == "tool_call"
      assert msg.tool_call_id == "call_abc"
      # the id is still in content too — the column is an additional denormalized copy
      assert msg.content["call_id"] == "call_abc"
      # tool calls start pending
      assert msg.status == "pending"
    end

    test "copies content[\"tool_call_id\"] into the tool_call_id column for tool_result rows" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message =
        Message.new_tool_result!(%{
          content: nil,
          tool_results: [
            ToolResult.new!(%{tool_call_id: "call_abc", name: "search", content: "Found"})
          ]
        })

      assert {:ok, [%DisplayMessage{} = msg]} =
               DisplayMessagePersistence.save_message(scope, message, context)

      assert msg.content_type == "tool_result"
      assert msg.tool_call_id == "call_abc"
      assert msg.content["tool_call_id"] == "call_abc"
    end

    test "leaves tool_call_id nil for non-tool content (text)" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message = Message.new_assistant!(%{content: "Just text, no tools."})

      assert {:ok, [%DisplayMessage{} = msg]} =
               DisplayMessagePersistence.save_message(scope, message, context)

      assert msg.content_type == "text"
      assert is_nil(msg.tool_call_id)
    end
  end

  describe "save_message/3 sequence assignment" do
    test "assigns an ascending sequence across the items of one message" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("Let me look"), ContentPart.text!("Searching now")],
          tool_calls: [
            ToolCall.new!(%{call_id: "call_abc", name: "search", arguments: %{"q" => "elixir"}})
          ]
        })

      assert {:ok, rows} = DisplayMessagePersistence.save_message(scope, message, context)

      assert [0, 1, 2] == Enum.map(rows, & &1.sequence)
      assert ["thinking", "text", "tool_call"] == Enum.map(rows, & &1.content_type)
    end

    test "the parts of one message load back in production order" do
      # End-to-end cover for the path the UI actually reads: it reloads after
      # every save rather than appending. This does not by itself pin the
      # sequence values — the assertion on ascending sequence above is what
      # catches those going flat.
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message =
        Message.new_assistant!(%{
          content: [ContentPart.thinking!("Let me look"), ContentPart.text!("Here it is")]
        })

      assert {:ok, _rows} = DisplayMessagePersistence.save_message(scope, message, context)

      assert ["thinking", "text"] ==
               scope
               |> Conversations.load_display_messages(conversation.id)
               |> Enum.map(& &1.content_type)
    end

    test "a single-item message still gets sequence 0" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message = Message.new_assistant!("Just text.")

      assert {:ok, [%DisplayMessage{sequence: 0}]} =
               DisplayMessagePersistence.save_message(scope, message, context)
    end
  end

  describe "save_message/3 stop reason" do
    test "carries the stop reason and provider detail into persisted content" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      details = %{"type" => "refusal", "category" => "cyber"}

      message = %Message{
        role: :assistant,
        content: [ContentPart.text!("I can't help with")],
        status: :content_filtered,
        metadata: %{stop_details: details}
      }

      assert {:ok, [%DisplayMessage{} = msg]} =
               DisplayMessagePersistence.save_message(scope, message, context)

      assert msg.content["stop_reason"] == "content_filtered"
      assert msg.content["stop_details"] == details
    end

    test "marks only the last item of a multi-part message" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message = %Message{
        role: :assistant,
        content: [ContentPart.thinking!("Working through"), ContentPart.text!("Here is the")],
        status: :length
      }

      assert {:ok, [thinking, text]} =
               DisplayMessagePersistence.save_message(scope, message, context)

      refute Map.has_key?(thinking.content, "stop_reason")
      assert text.content["stop_reason"] == "length"
    end

    test "a finished message writes no stop_reason key" do
      scope = user_scope_fixture()
      conversation = conversation_fixture(%{scope: scope})
      context = %{agent_id: "conversation-#{conversation.id}", conversation_id: conversation.id}

      message = Message.new_assistant!("All done.")

      assert {:ok, [%DisplayMessage{} = msg]} =
               DisplayMessagePersistence.save_message(scope, message, context)

      refute Map.has_key?(msg.content, "stop_reason")
      refute Map.has_key?(msg.content, "stop_details")
    end
  end
end

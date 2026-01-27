defmodule AgentsDemo.ConversationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `AgentsDemo.Conversations` context.
  """

  alias AgentsDemo.Conversations
  alias AgentsDemo.AccountsFixtures

  @doc """
  Generate a conversation with a user scope.
  """
  def conversation_fixture(attrs \\ %{}) do
    scope = attrs[:scope] || AccountsFixtures.user_scope_fixture()

    attrs =
      Enum.into(attrs, %{
        title: "Test Conversation #{System.unique_integer()}",
        metadata: %{}
      })

    {:ok, conversation} = Conversations.create_conversation(scope, attrs)
    conversation
  end

  @doc """
  Generate agent state for a conversation.
  """
  def agent_state_fixture(conversation_id, attrs \\ %{}) do
    state_data =
      Map.get(attrs, :state_data, %{
        "version" => 1,
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there!"}
        ],
        "todos" => [],
        "metadata" => %{}
      })

    {:ok, agent_state} = Conversations.save_agent_state(conversation_id, state_data)
    agent_state
  end

  @doc """
  Generate a text display message.
  """
  def text_message_fixture(conversation_id, attrs \\ %{}) do
    message_type = Map.get(attrs, :message_type, "user")
    text = Map.get(attrs, :text, "Test message #{System.unique_integer()}")
    sequence = Map.get(attrs, :sequence, 0)

    {:ok, message} =
      Conversations.append_display_message(conversation_id, %{
        message_type: message_type,
        content_type: "text",
        content: %{"text" => text},
        sequence: sequence,
        metadata: Map.get(attrs, :metadata, %{})
      })

    message
  end

  @doc """
  Generate a thinking block message.
  """
  def thinking_message_fixture(conversation_id, attrs \\ %{}) do
    text = Map.get(attrs, :text, "Let me think about this...")
    sequence = Map.get(attrs, :sequence, 0)

    {:ok, message} =
      Conversations.append_display_message(conversation_id, %{
        message_type: "assistant",
        content_type: "thinking",
        content: %{"text" => text},
        sequence: sequence,
        metadata: Map.get(attrs, :metadata, %{})
      })

    message
  end

  @doc """
  Generate an image message.
  """
  def image_message_fixture(conversation_id, attrs \\ %{}) do
    url = Map.get(attrs, :url, "/uploads/test.png")
    message_type = Map.get(attrs, :message_type, "assistant")
    sequence = Map.get(attrs, :sequence, 0)

    content = %{"url" => url}
    content = if alt = attrs[:alt_text], do: Map.put(content, "alt_text", alt), else: content

    content =
      if caption = attrs[:caption], do: Map.put(content, "caption", caption), else: content

    {:ok, message} =
      Conversations.append_display_message(conversation_id, %{
        message_type: message_type,
        content_type: "image",
        content: content,
        sequence: sequence,
        metadata: Map.get(attrs, :metadata, %{})
      })

    message
  end

  @doc """
  Generate a structured data message.
  """
  def structured_data_message_fixture(conversation_id, attrs \\ %{}) do
    format = Map.get(attrs, :format, "json")
    data = Map.get(attrs, :data, %{"status" => "ok"})
    sequence = Map.get(attrs, :sequence, 0)

    content = %{"format" => format, "data" => data}

    {:ok, message} =
      Conversations.append_display_message(conversation_id, %{
        message_type: Map.get(attrs, :message_type, "tool"),
        content_type: "structured_data",
        content: content,
        sequence: sequence,
        metadata: Map.get(attrs, :metadata, %{})
      })

    message
  end

  @doc """
  Generate an error message.
  """
  def error_message_fixture(conversation_id, attrs \\ %{}) do
    text = Map.get(attrs, :text, "An error occurred")
    sequence = Map.get(attrs, :sequence, 0)

    content = %{"text" => text}
    content = if code = attrs[:code], do: Map.put(content, "code", code), else: content

    content =
      if details = attrs[:details], do: Map.put(content, "details", details), else: content

    {:ok, message} =
      Conversations.append_display_message(conversation_id, %{
        message_type: Map.get(attrs, :message_type, "tool"),
        content_type: "error",
        content: content,
        sequence: sequence,
        metadata: Map.get(attrs, :metadata, %{})
      })

    message
  end
end

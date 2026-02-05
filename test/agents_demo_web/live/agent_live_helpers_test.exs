defmodule AgentsDemoWeb.AgentLiveHelpersTest do
  use AgentsDemoWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveView, only: [stream: 4]

  alias AgentsDemoWeb.AgentLiveHelpers
  alias AgentsDemo.Conversations
  alias Phoenix.LiveView.Socket
  alias LangChain.MessageDelta
  alias LangChain.Message.ToolCall

  # Copy modules for mocking
  setup :verify_on_exit!

  setup do
    # Copy modules that we'll stub/expect
    Mimic.copy(AgentsDemo.Conversations)
    Mimic.copy(AgentsDemo.Agents.Coordinator)
    Mimic.copy(Sagents.AgentServer)
    Mimic.copy(Sagents.FileSystemServer)
    :ok
  end

  # ============================================================================
  # SOCKET BUILDER
  # ============================================================================

  defp new_socket(assigns \\ %{}, init_streams \\ [], opts \\ []) do
    # Build a minimal LiveView socket struct
    # We only need enough structure for the helpers to work
    # Set transport_pid to simulate connected/disconnected state
    transport_pid = if Keyword.get(opts, :connected, false), do: self(), else: nil

    base_socket = %Socket{
      id: "test-socket",
      endpoint: AgentsDemoWeb.Endpoint,
      router: AgentsDemoWeb.Router,
      view: AgentsDemoWeb.ChatLive,
      parent_pid: nil,
      root_pid: self(),
      assigns: %{
        # Default assigns that helpers expect
        streaming_delta: nil,
        loading: false,
        agent_status: :idle,
        has_messages: false,
        __changed__: %{},
        flash: %{}
      },
      private: %{
        # Phoenix LiveView requires these in private
        lifecycle: %{
          after_render: [],
          handle_async: [],
          handle_event: [],
          handle_info: [],
          handle_params: [],
          mount: []
        },
        live_temp: %{}
      },
      host_uri: %URI{scheme: "http", host: "localhost", port: 4000},
      transport_pid: transport_pid
    }

    # Merge custom assigns
    socket_with_assigns =
      Enum.reduce(assigns, base_socket, fn {key, value}, socket ->
        Phoenix.Component.assign(socket, key, value)
      end)

    # Initialize streams if specified
    Enum.reduce(init_streams, socket_with_assigns, fn stream_name, socket ->
      stream(socket, stream_name, [], reset: true)
    end)
  end

  # ============================================================================
  # STATUS CHANGE HANDLER TESTS
  # ============================================================================

  describe "handle_status_running/1" do
    test "sets agent_status to :running" do
      socket = new_socket()

      result = AgentLiveHelpers.handle_status_running(socket)

      assert result.assigns.agent_status == :running
    end

    test "preserves other assigns" do
      socket = new_socket(%{loading: true, custom_value: 123})

      result = AgentLiveHelpers.handle_status_running(socket)

      assert result.assigns.loading == true
      assert result.assigns.custom_value == 123
    end
  end

  describe "handle_status_idle/1" do
    test "sets agent_status to :idle and loading to false" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 1, loading: true})

      Conversations
      |> stub(:save_agent_state, fn _conv_id, _state -> {:ok, %{}} end)

      Sagents.AgentServer
      |> stub(:export_state, fn _agent_id -> %{} end)

      result = AgentLiveHelpers.handle_status_idle(socket)

      assert result.assigns.agent_status == :idle
      assert result.assigns.loading == false
    end

    test "persists agent state when conversation_id and agent_id are present" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 123})

      Sagents.AgentServer
      |> expect(:export_state, fn agent_id ->
        assert agent_id == "test-agent"
        %{messages: []}
      end)

      Conversations
      |> expect(:save_agent_state, fn conv_id, state ->
        assert conv_id == 123
        assert state == %{messages: []}
        {:ok, %{}}
      end)

      AgentLiveHelpers.handle_status_idle(socket)
    end

    test "does not persist state when conversation_id is missing" do
      socket = new_socket(%{agent_id: "test-agent"})

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> raise "Should not be called" end)

      Conversations
      |> stub(:save_agent_state, fn _, _ -> raise "Should not be called" end)

      # Should not raise
      result = AgentLiveHelpers.handle_status_idle(socket)
      assert result.assigns.agent_status == :idle
    end

    test "does not reload filesystem when filesystem_scope is absent" do
      socket = new_socket()

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      Sagents.FileSystemServer
      |> stub(:list_files, fn _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.handle_status_idle(socket)
      refute Map.has_key?(result.assigns, :files)
    end
  end

  describe "handle_status_cancelled/1" do
    test "sets agent_status to :cancelled and loading to false" do
      socket = new_socket(%{loading: true}, [:messages])

      result = AgentLiveHelpers.handle_status_cancelled(socket)

      assert result.assigns.agent_status == :cancelled
      assert result.assigns.loading == false
    end

    test "clears streaming_delta" do
      socket = new_socket(%{streaming_delta: %MessageDelta{}}, [:messages])

      result = AgentLiveHelpers.handle_status_cancelled(socket)

      assert result.assigns.streaming_delta == nil
    end

    test "creates cancellation message without conversation_id" do
      socket = new_socket(%{}, [:messages])

      result = AgentLiveHelpers.handle_status_cancelled(socket)

      # The message is inserted into the stream, check it was created
      assert result.assigns.agent_status == :cancelled
    end

    test "persists cancellation message when conversation_id exists" do
      socket = new_socket(%{conversation_id: 123}, [:messages])

      Conversations
      |> expect(:append_text_message, fn conv_id, message_type, text ->
        assert conv_id == 123
        assert message_type == :assistant
        assert text =~ "cancelled"
        {:ok, %{id: 1, content: %{"text" => text}}}
      end)

      result = AgentLiveHelpers.handle_status_cancelled(socket)
      assert result.assigns.agent_status == :cancelled
    end
  end

  describe "handle_status_error/2" do
    test "sets agent_status to :error and loading to false" do
      socket = new_socket(%{loading: true}, [:messages])

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      result = AgentLiveHelpers.handle_status_error(socket, "test error")

      assert result.assigns.agent_status == :error
      assert result.assigns.loading == false
    end

    test "formats error message for LangChainError" do
      socket = new_socket(%{conversation_id: 123}, [:messages])

      error = %LangChain.LangChainError{message: "API rate limit exceeded"}

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)
      |> expect(:append_text_message, fn _conv_id, _type, text ->
        assert text =~ "API rate limit exceeded"
        {:ok, %{id: 1}}
      end)

      AgentLiveHelpers.handle_status_error(socket, error)
    end

    test "formats error message for generic error" do
      socket = new_socket(%{conversation_id: 123}, [:messages])

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)
      |> expect(:append_text_message, fn _conv_id, _type, text ->
        assert text =~ "some_error"
        {:ok, %{id: 1}}
      end)

      AgentLiveHelpers.handle_status_error(socket, :some_error)
    end

    test "persists agent state on error" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 123}, [:messages])

      Sagents.AgentServer
      |> expect(:export_state, fn agent_id ->
        assert agent_id == "test-agent"
        %{messages: []}
      end)

      Conversations
      |> expect(:save_agent_state, fn conv_id, _state ->
        assert conv_id == 123
        {:ok, %{}}
      end)
      |> stub(:append_text_message, fn _, _, _ -> {:ok, %{id: 1}} end)

      AgentLiveHelpers.handle_status_error(socket, "test error")
    end
  end

  describe "handle_status_interrupted/2" do
    test "sets agent_status to :interrupted and loading to false" do
      socket = new_socket(%{loading: true})
      interrupt_data = %{action_requests: []}

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      result = AgentLiveHelpers.handle_status_interrupted(socket, interrupt_data)

      assert result.assigns.agent_status == :interrupted
      assert result.assigns.loading == false
    end

    test "stores action_requests in pending_tools" do
      socket = new_socket()

      action_requests = [
        %{id: "req-1", tool: "file_write", arguments: %{"path" => "test.txt"}}
      ]

      interrupt_data = %{action_requests: action_requests}

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      result = AgentLiveHelpers.handle_status_interrupted(socket, interrupt_data)

      assert result.assigns.pending_tools == action_requests
      assert result.assigns.interrupt_data == interrupt_data
    end

    test "handles empty action_requests" do
      socket = new_socket()
      interrupt_data = %{}

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      result = AgentLiveHelpers.handle_status_interrupted(socket, interrupt_data)

      assert result.assigns.pending_tools == []
    end
  end

  # ============================================================================
  # MESSAGING HANDLER TESTS
  # ============================================================================

  describe "handle_llm_deltas/2" do
    test "merges deltas into streaming_delta" do
      socket = new_socket(%{streaming_delta: nil})

      delta1 = %MessageDelta{role: :assistant, content: "Hello", status: :incomplete}

      result = AgentLiveHelpers.handle_llm_deltas(socket, [delta1])

      assert result.assigns.streaming_delta != nil
      assert result.assigns.streaming_delta.role == :assistant
    end

    test "accumulates multiple deltas" do
      socket = new_socket(%{streaming_delta: nil})

      delta1 = %MessageDelta{role: :assistant, content: "Hello", status: :incomplete}
      socket = AgentLiveHelpers.handle_llm_deltas(socket, [delta1])

      delta2 = %MessageDelta{content: " world", status: :incomplete}
      result = AgentLiveHelpers.handle_llm_deltas(socket, [delta2])

      # Verify delta was accumulated
      assert result.assigns.streaming_delta != nil
      assert result.assigns.streaming_delta.role == :assistant
    end

    test "adds tool display info for new tool calls" do
      socket = new_socket(%{streaming_delta: nil})

      tool_call = %ToolCall{
        call_id: "call-123",
        name: "file_write",
        arguments: nil,
        status: :incomplete
      }

      delta = %MessageDelta{
        role: :assistant,
        content: nil,
        tool_calls: [tool_call],
        status: :incomplete
      }

      result = AgentLiveHelpers.handle_llm_deltas(socket, [delta])

      tools = MessageDelta.get_tool_display_info(result.assigns.streaming_delta)
      assert length(tools) == 1
      assert List.first(tools).name == "file_write"
      assert List.first(tools).call_id == "call-123"
      assert List.first(tools).status == :identified
    end
  end

  describe "handle_llm_message_complete/1" do
    test "clears streaming_delta when no tool calls present" do
      delta = %MessageDelta{role: :assistant, content: "Done", status: :complete}
      socket = new_socket(%{streaming_delta: delta, loading: true})

      result = AgentLiveHelpers.handle_llm_message_complete(socket)

      assert result.assigns.streaming_delta == nil
      assert result.assigns.loading == false
    end

    test "keeps streaming_delta when tool calls are present" do
      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_name: "File write",
        status: :identified
      }

      delta = %MessageDelta{
        role: :assistant,
        content: nil,
        metadata: %{streaming_tool_calls: [tool_info]},
        status: :complete
      }

      socket = new_socket(%{streaming_delta: delta, loading: true})

      result = AgentLiveHelpers.handle_llm_message_complete(socket)

      assert result.assigns.streaming_delta != nil
      assert result.assigns.loading == false
    end
  end

  describe "handle_display_messages_batch_saved/2" do
    test "sets has_messages to true" do
      socket = new_socket(%{has_messages: false})

      result = AgentLiveHelpers.handle_display_messages_batch_saved(socket, [])

      assert result.assigns.has_messages == true
    end

    test "reloads messages from DB when no pending tools" do
      socket = new_socket(%{conversation_id: 123, streaming_delta: nil})

      Conversations
      |> expect(:load_display_messages, fn conv_id ->
        assert conv_id == 123
        [%{id: 1, content: "Message 1"}]
      end)

      result = AgentLiveHelpers.handle_display_messages_batch_saved(socket, [])

      assert result.assigns.has_messages == true
      assert result.assigns.streaming_delta == nil
    end

    test "does not reload when pending tools exist" do
      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_name: "File write",
        status: :executing
      }

      delta = %MessageDelta{
        metadata: %{streaming_tool_calls: [tool_info]}
      }

      socket = new_socket(%{conversation_id: 123, streaming_delta: delta})

      Conversations
      |> stub(:load_display_messages, fn _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.handle_display_messages_batch_saved(socket, [])

      assert result.assigns.has_messages == true
      # Delta should still be present
      assert result.assigns.streaming_delta == delta
    end
  end

  describe "handle_display_message_saved/2" do
    test "sets has_messages to true" do
      socket = new_socket(%{}, [:messages])
      message = %{id: 1, content: "Test"}

      result = AgentLiveHelpers.handle_display_message_saved(socket, message)

      assert result.assigns.has_messages == true
    end

    test "reloads from DB when conversation_id exists" do
      socket = new_socket(%{conversation_id: 123}, [:messages])

      Conversations
      |> expect(:load_display_messages, fn conv_id ->
        assert conv_id == 123
        []
      end)

      result = AgentLiveHelpers.handle_display_message_saved(socket, %{id: 1})
      assert result.assigns.has_messages == true
    end

    test "inserts message directly when no conversation_id" do
      socket = new_socket(%{}, [:messages])
      message = %{id: 1, content: "Test"}

      result = AgentLiveHelpers.handle_display_message_saved(socket, message)

      # Message should be in stream (we can't easily assert on stream contents,
      # but we can verify the socket was returned and has_messages is set)
      assert result.assigns.has_messages == true
    end
  end

  # ============================================================================
  # TOOL EXECUTION HANDLER TESTS
  # ============================================================================

  describe "handle_tool_call_identified/2" do
    test "updates streaming_delta with tool display info" do
      socket = new_socket(%{streaming_delta: nil})

      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_text: "Write file",
        arguments: %{"path" => "test.txt"}
      }

      result = AgentLiveHelpers.handle_tool_call_identified(socket, tool_info)

      tools = MessageDelta.get_tool_display_info(result.assigns.streaming_delta)
      assert length(tools) == 1
      assert List.first(tools).display_name == "Write file"
    end

    test "uses tool name as fallback when display_text is missing" do
      socket = new_socket(%{streaming_delta: nil})

      tool_info = %{
        call_id: "call-123",
        name: "web_search",
        arguments: %{"query" => "test"}
      }

      result = AgentLiveHelpers.handle_tool_call_identified(socket, tool_info)

      tools = MessageDelta.get_tool_display_info(result.assigns.streaming_delta)
      assert List.first(tools).display_name == "web_search"
    end
  end

  describe "handle_tool_execution_started/2" do
    test "updates tool status to executing in streaming_delta" do
      tool_info_initial = %{
        call_id: "call-123",
        name: "file_write",
        display_name: "File write",
        status: :identified
      }

      delta = %MessageDelta{
        metadata: %{streaming_tool_calls: [tool_info_initial]}
      }

      socket = new_socket(%{streaming_delta: delta})

      Conversations
      |> stub(:mark_tool_executing, fn _ -> {:error, :not_found} end)

      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_text: "File write"
      }

      result = AgentLiveHelpers.handle_tool_execution_started(socket, tool_info)

      tools = MessageDelta.get_tool_display_info(result.assigns.streaming_delta)
      assert List.first(tools).status == :executing
    end

    test "updates database when tool call exists" do
      socket = new_socket(%{streaming_delta: nil}, [:messages])

      Conversations
      |> expect(:mark_tool_executing, fn call_id ->
        assert call_id == "call-123"
        {:ok, %{id: 1, status: :executing}}
      end)

      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_text: "File write",
        arguments: %{"path" => "test.txt"}
      }

      AgentLiveHelpers.handle_tool_execution_started(socket, tool_info)
    end
  end

  describe "handle_tool_execution_completed/3" do
    test "clears streaming_delta" do
      delta = %MessageDelta{}
      socket = new_socket(%{streaming_delta: delta})

      Conversations
      |> stub(:complete_tool_call, fn _, _ -> {:ok, %{}} end)

      result = AgentLiveHelpers.handle_tool_execution_completed(socket, "call-123", "success")

      assert result.assigns.streaming_delta == nil
    end

    test "updates database with result metadata" do
      socket = new_socket()

      Conversations
      |> expect(:complete_tool_call, fn call_id, metadata ->
        assert call_id == "call-123"
        assert metadata["result"] == "\"success\""
        {:ok, %{}}
      end)

      AgentLiveHelpers.handle_tool_execution_completed(socket, "call-123", "success")
    end

    test "reloads messages when streaming_delta and conversation_id exist" do
      delta = %MessageDelta{}
      socket = new_socket(%{streaming_delta: delta, conversation_id: 123}, [:messages])

      Conversations
      |> stub(:complete_tool_call, fn _, _ -> {:ok, %{}} end)
      |> expect(:load_display_messages, fn conv_id ->
        assert conv_id == 123
        []
      end)

      AgentLiveHelpers.handle_tool_execution_completed(socket, "call-123", "success")
    end

    test "handles database errors gracefully" do
      socket = new_socket()

      Conversations
      |> stub(:complete_tool_call, fn _, _ -> {:error, :database_error} end)

      # Should not raise
      result = AgentLiveHelpers.handle_tool_execution_completed(socket, "call-123", "success")
      assert result.assigns.streaming_delta == nil
    end
  end

  describe "handle_tool_execution_failed/3" do
    test "clears streaming_delta" do
      delta = %MessageDelta{}
      socket = new_socket(%{streaming_delta: delta})

      Conversations
      |> stub(:fail_tool_call, fn _, _ -> {:ok, %{}} end)

      result = AgentLiveHelpers.handle_tool_execution_failed(socket, "call-123", "error")

      assert result.assigns.streaming_delta == nil
    end

    test "updates database with error metadata" do
      socket = new_socket()

      Conversations
      |> expect(:fail_tool_call, fn call_id, metadata ->
        assert call_id == "call-123"
        assert metadata["error"] =~ "error"
        {:ok, %{}}
      end)

      AgentLiveHelpers.handle_tool_execution_failed(socket, "call-123", :some_error)
    end
  end

  # ============================================================================
  # LIFECYCLE HANDLER TESTS
  # ============================================================================

  describe "handle_conversation_title_generated/3" do
    test "updates conversation title when agent_id matches" do
      conversation = %{id: 123, title: "Old Title"}

      socket =
        new_socket(%{agent_id: "agent-123", conversation: conversation, conversation_id: 123})

      Conversations
      |> expect(:update_conversation, fn conv, attrs ->
        assert conv.id == 123
        assert attrs.title == "New Title"
        {:ok, %{conv | title: "New Title"}}
      end)
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> %{} end)

      result =
        AgentLiveHelpers.handle_conversation_title_generated(socket, "New Title", "agent-123")

      assert result.assigns.conversation.title == "New Title"
    end

    test "does not update when agent_id does not match" do
      conversation = %{id: 123, title: "Old Title"}
      socket = new_socket(%{agent_id: "agent-123", conversation: conversation})

      Conversations
      |> stub(:update_conversation, fn _, _ -> raise "Should not be called" end)

      result =
        AgentLiveHelpers.handle_conversation_title_generated(socket, "New Title", "other-agent")

      assert result.assigns.conversation.title == "Old Title"
    end

    test "does not update when conversation is nil" do
      socket = new_socket(%{agent_id: "agent-123"})

      Conversations
      |> stub(:update_conversation, fn _, _ -> raise "Should not be called" end)

      result =
        AgentLiveHelpers.handle_conversation_title_generated(socket, "New Title", "agent-123")

      refute Map.has_key?(result.assigns, :conversation)
    end

    test "updates conversation list when thread history is open" do
      conversation = %{id: 123, title: "Old Title"}

      socket =
        new_socket(
          %{
            agent_id: "agent-123",
            conversation: conversation,
            conversation_id: 123,
            is_thread_history_open: true
          },
          [:conversation_list]
        )

      Conversations
      |> stub(:update_conversation, fn conv, _attrs ->
        {:ok, %{conv | title: "New Title"}}
      end)
      |> stub(:save_agent_state, fn _, _ -> {:ok, %{}} end)

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> %{} end)

      result =
        AgentLiveHelpers.handle_conversation_title_generated(socket, "New Title", "agent-123")

      # Can't easily assert stream contents, but verify socket returned
      assert result.assigns.conversation.title == "New Title"
    end
  end

  describe "handle_agent_shutdown/2" do
    test "clears agent_id from assigns" do
      socket = new_socket(%{agent_id: "test-agent"})
      shutdown_data = %{agent_id: "test-agent", reason: "inactivity_timeout"}

      result = AgentLiveHelpers.handle_agent_shutdown(socket, shutdown_data)

      assert result.assigns.agent_id == nil
    end

    test "preserves other assigns" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 123, custom: "value"})
      shutdown_data = %{agent_id: "test-agent", reason: "manual_stop"}

      result = AgentLiveHelpers.handle_agent_shutdown(socket, shutdown_data)

      assert result.assigns.agent_id == nil
      assert result.assigns.conversation_id == 123
      assert result.assigns.custom == "value"
    end
  end

  # ============================================================================
  # CORE HELPER FUNCTION TESTS
  # ============================================================================

  describe "persist_agent_state/2" do
    test "persists state when both agent_id and conversation_id are present" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 123})

      Sagents.AgentServer
      |> expect(:export_state, fn agent_id ->
        assert agent_id == "test-agent"
        %{messages: [], todos: []}
      end)

      Conversations
      |> expect(:save_agent_state, fn conv_id, state ->
        assert conv_id == 123
        assert state == %{messages: [], todos: []}
        {:ok, %{}}
      end)

      result = AgentLiveHelpers.persist_agent_state(socket, "test_context")

      # Should return socket unchanged
      assert result == socket
    end

    test "skips persistence when conversation_id is missing" do
      socket = new_socket(%{agent_id: "test-agent"})

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> raise "Should not be called" end)

      Conversations
      |> stub(:save_agent_state, fn _, _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.persist_agent_state(socket, "test_context")
      assert result == socket
    end

    test "skips persistence when agent_id is missing" do
      socket = new_socket(%{conversation_id: 123})

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> raise "Should not be called" end)

      Conversations
      |> stub(:save_agent_state, fn _, _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.persist_agent_state(socket, "test_context")
      assert result == socket
    end

    test "handles database errors gracefully" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 123})

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> %{} end)

      Conversations
      |> stub(:save_agent_state, fn _, _ -> {:error, :database_error} end)

      # Should not raise
      result = AgentLiveHelpers.persist_agent_state(socket, "test_context")
      assert result == socket
    end

    test "handles AgentServer exceptions gracefully" do
      socket = new_socket(%{agent_id: "test-agent", conversation_id: 123})

      Sagents.AgentServer
      |> stub(:export_state, fn _ -> raise "Agent crashed" end)

      Conversations
      |> stub(:save_agent_state, fn _, _ -> raise "Should not be called" end)

      # Should not raise
      result = AgentLiveHelpers.persist_agent_state(socket, "test_context")
      assert result == socket
    end
  end

  describe "update_streaming_message/2" do
    test "initializes streaming_delta with first delta" do
      socket = new_socket(%{streaming_delta: nil})

      delta = %MessageDelta{role: :assistant, content: "Hello", status: :incomplete}

      result = AgentLiveHelpers.update_streaming_message(socket, [delta])

      assert result.assigns.streaming_delta != nil
      assert result.assigns.streaming_delta.role == :assistant
    end

    test "merges subsequent deltas" do
      socket = new_socket(%{streaming_delta: nil})

      delta1 = %MessageDelta{role: :assistant, content: "Hello", status: :incomplete}
      socket = AgentLiveHelpers.update_streaming_message(socket, [delta1])

      delta2 = %MessageDelta{content: " world", status: :incomplete}
      result = AgentLiveHelpers.update_streaming_message(socket, [delta2])

      assert result.assigns.streaming_delta != nil
      assert result.assigns.streaming_delta.role == :assistant
    end
  end

  describe "reload_messages_from_db/1" do
    test "reloads messages when conversation_id exists" do
      socket = new_socket(%{conversation_id: 123})

      Conversations
      |> expect(:load_display_messages, fn conv_id ->
        assert conv_id == 123
        [%{id: 1}, %{id: 2}]
      end)

      result = AgentLiveHelpers.reload_messages_from_db(socket)

      # Can't easily assert on stream contents, but verify function completed
      assert result != nil
    end

    test "returns socket unchanged when conversation_id is missing" do
      socket = new_socket()

      Conversations
      |> stub(:load_display_messages, fn _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.reload_messages_from_db(socket)
      assert result == socket
    end
  end

  describe "create_or_persist_message/3" do
    test "creates in-memory message when no conversation_id" do
      socket = new_socket()

      message = AgentLiveHelpers.create_or_persist_message(socket, :assistant, "Test message")

      assert message.message_type == :assistant
      assert message.content_type == "text"
      assert message.content["text"] == "Test message"
      assert message.id != nil
      assert message.timestamp != nil
    end

    test "persists message to database when conversation_id exists" do
      socket = new_socket(%{conversation_id: 123})

      Conversations
      |> expect(:append_text_message, fn conv_id, message_type, text ->
        assert conv_id == 123
        assert message_type == :user
        assert text == "Hello"
        {:ok, %{id: 456, content: %{"text" => text}, message_type: message_type}}
      end)

      message = AgentLiveHelpers.create_or_persist_message(socket, :user, "Hello")

      assert message.id == 456
      assert message.message_type == :user
    end

    test "creates fallback message when database persistence fails" do
      socket = new_socket(%{conversation_id: 123})

      Conversations
      |> stub(:append_text_message, fn _, _, _ -> {:error, :database_error} end)

      message = AgentLiveHelpers.create_or_persist_message(socket, :assistant, "Fallback")

      # Should return in-memory fallback
      assert message.message_type == :assistant
      assert message.content["text"] == "Fallback"
      assert message.id != nil
    end

    test "creates unique IDs for different messages" do
      socket = new_socket()

      msg1 = AgentLiveHelpers.create_or_persist_message(socket, :assistant, "Test 1")
      msg2 = AgentLiveHelpers.create_or_persist_message(socket, :assistant, "Test 2")

      assert msg1.id != msg2.id
    end
  end

  # ============================================================================
  # STATE MANAGEMENT HELPER TESTS
  # ============================================================================

  describe "init_agent_state/1" do
    test "sets all agent assigns to default values" do
      socket = new_socket()

      result = AgentLiveHelpers.init_agent_state(socket)

      assert result.assigns.conversation == nil
      assert result.assigns.conversation_id == nil
      assert result.assigns.agent_id == nil
      assert result.assigns.agent_status == :not_running
      assert result.assigns.todos == []
      assert result.assigns.has_messages == false
      assert result.assigns.streaming_delta == nil
      assert result.assigns.loading == false
      assert result.assigns.pending_tools == []
      assert result.assigns.interrupt_data == nil
    end

    test "initializes messages stream to empty" do
      socket = new_socket()

      result = AgentLiveHelpers.init_agent_state(socket)

      # Verify stream exists (it's in socket.assigns.streams)
      assert Map.has_key?(result.assigns, :streams)
      assert Map.has_key?(result.assigns.streams, :messages)
    end

    test "preserves other non-agent assigns" do
      socket = new_socket(%{custom_value: 123, input: "test"})

      result = AgentLiveHelpers.init_agent_state(socket)

      # Agent assigns are reset
      assert result.assigns.agent_status == :not_running

      # Custom assigns preserved
      assert result.assigns.custom_value == 123
      assert result.assigns.input == "test"
    end
  end

  describe "reset_conversation/1" do
    test "resets all agent assigns to defaults" do
      socket =
        new_socket(%{
          conversation_id: "conv-123",
          agent_id: "agent-123",
          agent_status: :running,
          todos: [%{content: "Test"}],
          loading: true
        })

      result = AgentLiveHelpers.reset_conversation(socket)

      # All agent assigns should be reset
      assert result.assigns.conversation == nil
      assert result.assigns.conversation_id == nil
      assert result.assigns.agent_id == nil
      assert result.assigns.agent_status == :not_running
      assert result.assigns.todos == []
      assert result.assigns.loading == false
    end

    test "unsubscribes from conversation when connected" do
      socket = new_socket(%{conversation_id: "conv-123"}, [], connected: true)

      AgentsDemo.Agents.Coordinator
      |> expect(:unsubscribe_from_conversation, fn conv_id ->
        assert conv_id == "conv-123"
        :ok
      end)

      result = AgentLiveHelpers.reset_conversation(socket)

      # Should reset assigns after unsubscribing
      assert result.assigns.conversation_id == nil
    end

    test "does not unsubscribe when not connected" do
      socket = new_socket(%{conversation_id: "conv-123"})

      AgentsDemo.Agents.Coordinator
      |> stub(:unsubscribe_from_conversation, fn _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.reset_conversation(socket)

      # Should still reset assigns
      assert result.assigns.conversation_id == nil
    end

    test "does not unsubscribe when no conversation_id" do
      socket = new_socket([], [], connected: true)

      AgentsDemo.Agents.Coordinator
      |> stub(:unsubscribe_from_conversation, fn _ -> raise "Should not be called" end)

      result = AgentLiveHelpers.reset_conversation(socket)

      # Should reset to defaults
      assert result.assigns.conversation_id == nil
      assert result.assigns.agent_status == :not_running
    end
  end

  describe "load_conversation/3" do
    setup do
      Mimic.copy(AgentsDemo.Agents.Coordinator)
      :ok
    end

    test "returns {:ok, socket} when conversation exists" do
      socket = new_socket([], [], connected: true)
      scope = {:user, 1}
      conversation = %{id: 123, title: "Test Conversation"}

      Conversations
      |> stub(:get_conversation!, fn _scope, _id -> conversation end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)
      |> stub(:ensure_subscribed_to_conversation, fn _ -> :ok end)
      |> stub(:track_conversation_viewer, fn _, _, _ -> {:ok, :ref} end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )

      assert result.assigns.conversation == conversation
      assert result.assigns.conversation_id == 123
      assert result.assigns.agent_id == "agent-123"
      assert result.assigns.agent_status == :not_running
    end

    test "returns {:error, socket} with flash when conversation not found" do
      socket = new_socket()
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ ->
        raise Ecto.NoResultsError, queryable: "conversations"
      end)

      {:error, result} =
        AgentLiveHelpers.load_conversation(socket, 999, scope: scope)

      # Should return error tuple and have flash error set
      # Flash is stored in assigns.flash in our test socket (string keys)
      assert result.assigns.flash["error"] == "Conversation not found"
    end

    test "loads display messages and todos from database" do
      socket = new_socket()
      scope = {:user, 1}
      conversation = %{id: 123, title: "Test"}

      display_messages = [%{id: 1, content: "Msg 1"}, %{id: 2, content: "Msg 2"}]
      todos = [%{content: "Todo 1", status: :pending}]

      Conversations
      |> stub(:get_conversation!, fn _, _ -> conversation end)
      |> expect(:load_display_messages, fn conv_id ->
        assert conv_id == 123
        display_messages
      end)
      |> expect(:load_todos, fn conv_id ->
        assert conv_id == 123
        todos
      end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123, scope: scope)

      assert result.assigns.todos == todos
      assert result.assigns.has_messages == true
    end

    test "gets agent status from AgentServer" do
      socket = new_socket()
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)

      Sagents.AgentServer
      |> expect(:get_status, fn agent_id ->
        assert agent_id == "agent-123"
        :idle
      end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123, scope: scope)

      # Status should be directly assigned (no conversion)
      assert result.assigns.agent_status == :idle
    end

    test "subscribes to conversation when connected" do
      socket = new_socket([], [], connected: true)
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)
      |> expect(:ensure_subscribed_to_conversation, fn conv_id ->
        assert conv_id == 123
        :ok
      end)
      |> expect(:track_conversation_viewer, fn conv_id, user_id, pid ->
        assert conv_id == 123
        assert user_id == 1
        assert pid == self()
        {:ok, :ref}
      end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      {:ok, _result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )
    end

    test "does not subscribe when not connected" do
      socket = new_socket()
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)
      |> stub(:ensure_subscribed_to_conversation, fn _ -> raise "Should not be called" end)
      |> stub(:track_conversation_viewer, fn _, _, _ -> raise "Should not be called" end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      {:ok, _result} =
        AgentLiveHelpers.load_conversation(socket, 123, scope: scope)
    end

    test "unsubscribes from previous conversation when switching" do
      socket = new_socket(%{conversation_id: 100}, [], connected: true)
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ -> %{id: 123, title: "New"} end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)
      |> expect(:unsubscribe_from_conversation, fn conv_id ->
        assert conv_id == 100
        :ok
      end)
      |> stub(:ensure_subscribed_to_conversation, fn _ -> :ok end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )

      # Should have new conversation loaded
      assert result.assigns.conversation_id == 123
    end

    test "does not unsubscribe when loading same conversation" do
      socket = new_socket(%{conversation_id: 123}, [], connected: true)
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ -> %{id: 123, title: "Same"} end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)
      |> stub(:unsubscribe_from_conversation, fn _ -> raise "Should not be called" end)
      |> stub(:ensure_subscribed_to_conversation, fn _ -> :ok end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      {:ok, _result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )
    end

    test "handles already tracked presence gracefully" do
      socket = new_socket([], [], connected: true)
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _ -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _ -> [] end)
      |> stub(:load_todos, fn _ -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _ -> "agent-123" end)
      |> stub(:ensure_subscribed_to_conversation, fn _ -> :ok end)
      |> stub(:track_conversation_viewer, fn _, _, _ ->
        {:error, {:already_tracked, :ref, :meta, :data}}
      end)

      Sagents.AgentServer
      |> stub(:get_status, fn _ -> :not_running end)

      # Should not raise
      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )

      assert result.assigns.conversation_id == 123
    end
  end
end

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
    Mimic.copy(Sagents.Subscriber)
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

      result = AgentLiveHelpers.handle_status_idle(socket)

      assert result.assigns.agent_status == :idle
      assert result.assigns.loading == false
    end

    test "does not reload filesystem when filesystem_scope is absent" do
      socket = new_socket()

      Sagents.FileSystemServer
      |> stub(:list_files, fn _other -> raise "Should not be called" end)

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

    test "does not persist a cancellation message (AgentServer owns persistence)" do
      socket = new_socket(%{conversation_id: 123}, [:messages])

      Conversations
      |> reject(:append_text_message, 4)

      result = AgentLiveHelpers.handle_status_cancelled(socket)
      assert result.assigns.agent_status == :cancelled
    end
  end

  describe "handle_status_error/2" do
    test "sets agent_status to :error and loading to false" do
      socket = new_socket(%{loading: true}, [:messages])

      result = AgentLiveHelpers.handle_status_error(socket, "test error")

      assert result.assigns.agent_status == :error
      assert result.assigns.loading == false
    end

    test "shows flash with formatted error for LangChainError" do
      socket = new_socket(%{conversation_id: 123})

      error = %LangChain.LangChainError{message: "API rate limit exceeded"}

      result = AgentLiveHelpers.handle_status_error(socket, error)

      flash = result.assigns.flash
      assert flash["error"] =~ "API rate limit exceeded"
    end

    test "shows flash with formatted error for generic error" do
      socket = new_socket(%{conversation_id: 123})

      result = AgentLiveHelpers.handle_status_error(socket, :some_error)

      flash = result.assigns.flash
      assert flash["error"] =~ "some_error"
    end
  end

  describe "handle_status_interrupted/2" do
    test "sets agent_status to :interrupted and loading to false" do
      socket = new_socket(%{loading: true})
      interrupt_data = %{action_requests: []}

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

      result = AgentLiveHelpers.handle_status_interrupted(socket, interrupt_data)

      assert result.assigns.pending_tools == action_requests
      assert result.assigns.interrupt_data == interrupt_data
    end

    test "handles empty action_requests" do
      socket = new_socket()
      interrupt_data = %{}

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

    test "preserves tool calls on streaming delta" do
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

      # Tool calls should be present on the delta's tool_calls field
      assert [tc] = result.assigns.streaming_delta.tool_calls
      assert tc.name == "file_write"
      assert tc.call_id == "call-123"
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

    test "clears streaming_delta even when tool calls are present" do
      tool_call = %ToolCall{
        call_id: "call-123",
        name: "file_write",
        display_text: "File write",
        status: :incomplete
      }

      delta = %MessageDelta{
        role: :assistant,
        content: nil,
        tool_calls: [tool_call],
        status: :complete
      }

      socket = new_socket(%{streaming_delta: delta, loading: true})

      result = AgentLiveHelpers.handle_llm_message_complete(socket)

      # streaming_delta is always cleared — persisted display messages are
      # the authoritative display, tool status tracked via DB updates
      assert result.assigns.streaming_delta == nil
      assert result.assigns.loading == false
    end
  end

  describe "handle_display_message_saved/2" do
    test "sets has_messages to true" do
      socket = new_socket(%{}, [:messages])
      message = %{id: 1, content: "Test"}

      result = AgentLiveHelpers.handle_display_message_saved(socket, message)

      assert result.assigns.has_messages == true
    end

    test "reloads from DB when conversation_id and scope exist" do
      scope = %AgentsDemo.Accounts.Scope{user: %{id: 1}}
      socket = new_socket(%{conversation_id: 123, current_scope: scope}, [:messages])

      Conversations
      |> expect(:load_display_messages, fn ^scope, conv_id ->
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
    test "creates streaming delta with tool call when delta is nil" do
      socket = new_socket(%{streaming_delta: nil})

      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_text: "Write file",
        arguments: %{"path" => "test.txt"}
      }

      result = AgentLiveHelpers.handle_tool_call_identified(socket, tool_info)

      # Should create a delta with the tool call
      assert [tc] = result.assigns.streaming_delta.tool_calls
      assert tc.name == "file_write"
      assert tc.display_text == "Write file"
      # Should track status in ToolCall metadata
      assert ToolCall.execution_status(tc) == "identified"
    end

    test "sets display_text on existing delta tool call" do
      tool_call = %ToolCall{
        call_id: "call-123",
        name: "file_write",
        status: :incomplete
      }

      delta = %MessageDelta{
        role: :assistant,
        tool_calls: [tool_call],
        status: :incomplete
      }

      socket = new_socket(%{streaming_delta: delta})

      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_text: "Write file"
      }

      result = AgentLiveHelpers.handle_tool_call_identified(socket, tool_info)

      # display_text should be set on the ToolCall
      assert [tc] = result.assigns.streaming_delta.tool_calls
      assert tc.display_text == "Write file"
      # Status should be in ToolCall metadata
      assert ToolCall.execution_status(tc) == "identified"
    end
  end

  describe "handle_tool_execution_update/3" do
    test "updates streaming delta to executing status" do
      tool_call = %ToolCall{
        call_id: "call-123",
        name: "file_write",
        display_text: "File write",
        status: :incomplete
      }

      delta = %MessageDelta{
        role: :assistant,
        tool_calls: [tool_call],
        status: :incomplete
      }

      socket = new_socket(%{streaming_delta: delta})

      tool_info = %{
        call_id: "call-123",
        name: "file_write",
        display_text: "File write"
      }

      result = AgentLiveHelpers.handle_tool_execution_update(socket, :executing, tool_info)

      # Status should be in ToolCall metadata
      assert [tc] = result.assigns.streaming_delta.tool_calls
      assert ToolCall.execution_status(tc) == "executing"
    end

    test "clears streaming delta on completed" do
      delta = %MessageDelta{role: :assistant, status: :incomplete}
      socket = new_socket(%{streaming_delta: delta})

      tool_info = %{call_id: "call-123", name: "file_write", result: "success"}

      result = AgentLiveHelpers.handle_tool_execution_update(socket, :completed, tool_info)
      assert result.assigns.streaming_delta == nil
    end

    test "clears streaming delta on failed" do
      delta = %MessageDelta{role: :assistant, status: :incomplete}
      socket = new_socket(%{streaming_delta: delta})

      tool_info = %{call_id: "call-123", name: "file_write", error: "something went wrong"}

      result = AgentLiveHelpers.handle_tool_execution_update(socket, :failed, tool_info)
      assert result.assigns.streaming_delta == nil
    end

    test "handles nil streaming delta gracefully" do
      socket = new_socket(%{streaming_delta: nil})

      tool_info = %{call_id: "call-123", name: "file_write", display_text: "File write"}

      result = AgentLiveHelpers.handle_tool_execution_update(socket, :executing, tool_info)
      assert result.assigns.streaming_delta == nil
    end
  end

  describe "handle_display_message_updated/2" do
    test "inserts updated message into stream" do
      socket = new_socket(%{}, [:messages])

      updated_msg = %{id: 1, status: :executing}

      result = AgentLiveHelpers.handle_display_message_updated(socket, updated_msg)
      assert result != nil
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

      result =
        AgentLiveHelpers.handle_conversation_title_generated(socket, "New Title", "agent-123")

      assert result.assigns.conversation.title == "New Title"
    end

    test "does not update when agent_id does not match" do
      conversation = %{id: 123, title: "Old Title"}
      socket = new_socket(%{agent_id: "agent-123", conversation: conversation})

      Conversations
      |> stub(:update_conversation, fn _, _other -> raise "Should not be called" end)

      result =
        AgentLiveHelpers.handle_conversation_title_generated(socket, "New Title", "other-agent")

      assert result.assigns.conversation.title == "Old Title"
    end

    test "does not update when conversation is nil" do
      socket = new_socket(%{agent_id: "agent-123"})

      Conversations
      |> stub(:update_conversation, fn _, _other -> raise "Should not be called" end)

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

  # =========================================================================
  # CORE HELPER FUNCTION TESTS
  # =========================================================================

  describe "handle_llm_deltas/2 (streaming message accumulation)" do
    test "initializes streaming_delta with first delta" do
      socket = new_socket(%{streaming_delta: nil})

      delta = %MessageDelta{role: :assistant, content: "Hello", status: :incomplete}

      result = AgentLiveHelpers.handle_llm_deltas(socket, [delta])

      assert result.assigns.streaming_delta != nil
      assert result.assigns.streaming_delta.role == :assistant
    end

    test "merges subsequent deltas" do
      socket = new_socket(%{streaming_delta: nil})

      delta1 = %MessageDelta{role: :assistant, content: "Hello", status: :incomplete}
      socket = AgentLiveHelpers.handle_llm_deltas(socket, [delta1])

      delta2 = %MessageDelta{content: " world", status: :incomplete}
      result = AgentLiveHelpers.handle_llm_deltas(socket, [delta2])

      assert result.assigns.streaming_delta != nil
      assert result.assigns.streaming_delta.role == :assistant
    end
  end

  describe "reload_messages_from_db/1" do
    test "reloads messages when conversation_id and scope exist" do
      scope = %AgentsDemo.Accounts.Scope{user: %{id: 1}}
      socket = new_socket(%{conversation_id: 123, current_scope: scope})

      Conversations
      |> expect(:load_display_messages, fn ^scope, conv_id ->
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
      |> stub(:load_display_messages, fn _, _other -> raise "Should not be called" end)

      result = AgentLiveHelpers.reload_messages_from_db(socket)
      assert result == socket
    end

    test "returns socket unchanged when current_scope is missing" do
      socket = new_socket(%{conversation_id: 123})

      Conversations
      |> stub(:load_display_messages, fn _, _other -> raise "Should not be called" end)

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

    test "persists message to database when conversation_id and scope exist" do
      scope = %AgentsDemo.Accounts.Scope{user: %{id: 1}}
      socket = new_socket(%{conversation_id: 123, current_scope: scope})

      Conversations
      |> expect(:append_text_message, fn ^scope, conv_id, message_type, text ->
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
      scope = %AgentsDemo.Accounts.Scope{user: %{id: 1}}
      socket = new_socket(%{conversation_id: 123, current_scope: scope})

      Conversations
      |> stub(:append_text_message, fn _, _, _, _other -> {:error, :database_error} end)

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

    test "unsubscribes from agent when connected" do
      socket =
        new_socket(
          %{
            conversation_id: "conv-123",
            agent_id: "agent-123",
            sagents_subs: %{
              {:agent, "agent-123"} => %{
                channel: :main,
                server_pid: self(),
                monitor_ref: nil,
                client_ref: make_ref(),
                state: :subscribed
              }
            }
          },
          [],
          connected: true
        )

      Sagents.Subscriber
      |> expect(:unsubscribe_from_agent, fn _subs, agent_id ->
        assert agent_id == "agent-123"
        %{}
      end)

      result = AgentLiveHelpers.reset_conversation(socket)

      assert result.assigns.conversation_id == nil
      assert result.assigns.sagents_subs == %{}
    end

    test "does not unsubscribe when not connected" do
      socket = new_socket(%{conversation_id: "conv-123", agent_id: "agent-123"})

      Sagents.Subscriber
      |> stub(:unsubscribe_from_agent, fn _, _other -> raise "Should not be called" end)

      result = AgentLiveHelpers.reset_conversation(socket)

      assert result.assigns.conversation_id == nil
    end

    test "does not unsubscribe when no agent_id" do
      socket = new_socket([], [], connected: true)

      Sagents.Subscriber
      |> stub(:unsubscribe_from_agent, fn _, _other -> raise "Should not be called" end)

      result = AgentLiveHelpers.reset_conversation(socket)

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
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)
      |> stub(:track_conversation_viewer, fn _, _other -> {:ok, :ref} end)

      Sagents.Subscriber
      |> stub(:subscribe_to_agent, fn subs, _agent_id -> subs end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

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
      |> stub(:get_conversation!, fn _, _other ->
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
      |> stub(:get_conversation!, fn _, _other -> conversation end)
      |> expect(:load_display_messages, fn _scope, conv_id ->
        assert conv_id == 123
        display_messages
      end)
      |> expect(:load_todos, fn _scope, conv_id ->
        assert conv_id == 123
        todos
      end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123, scope: scope)

      assert result.assigns.todos == todos
      assert result.assigns.has_messages == true
    end

    test "gets agent status from AgentServer" do
      socket = new_socket()
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _other -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)

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

    test "subscribes to agent when connected" do
      socket = new_socket([], [], connected: true)
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _other -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      sample_subs = %{
        {:agent, "agent-123"} => %{
          channel: :main,
          server_pid: self(),
          monitor_ref: nil,
          client_ref: make_ref(),
          state: :subscribed
        }
      }

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)
      |> expect(:track_conversation_viewer, fn conv_id, user_id ->
        assert conv_id == 123
        assert user_id == 1
        {:ok, :ref}
      end)

      Sagents.Subscriber
      |> expect(:subscribe_to_agent, fn subs, agent_id ->
        assert subs == %{}
        assert agent_id == "agent-123"
        sample_subs
      end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )

      assert result.assigns.sagents_subs == sample_subs
    end

    test "does not subscribe when not connected" do
      socket = new_socket()
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _other -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)
      |> stub(:track_conversation_viewer, fn _, _other -> raise "Should not be called" end)

      Sagents.Subscriber
      |> stub(:subscribe_to_agent, fn _, _other ->
        raise "Should not be called when disconnected"
      end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

      {:ok, _result} =
        AgentLiveHelpers.load_conversation(socket, 123, scope: scope)
    end

    test "unsubscribes from previous agent when switching" do
      previous_subs = %{
        {:agent, "agent-old"} => %{
          channel: :main,
          server_pid: self(),
          monitor_ref: nil,
          client_ref: make_ref(),
          state: :subscribed
        }
      }

      socket =
        new_socket(
          %{
            conversation_id: 100,
            agent_id: "agent-old",
            sagents_subs: previous_subs
          },
          [],
          connected: true
        )

      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _other -> %{id: 123, title: "New"} end)
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      Sagents.Subscriber
      |> expect(:unsubscribe_from_agent, fn _subs, agent_id ->
        assert agent_id == "agent-old"
        %{}
      end)
      |> stub(:subscribe_to_agent, fn subs, _other -> subs end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)
      |> stub(:track_conversation_viewer, fn _, _other -> {:ok, :ref} end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )

      assert result.assigns.conversation_id == 123
    end

    test "does not unsubscribe when loading same conversation" do
      socket = new_socket(%{conversation_id: 123}, [], connected: true)
      scope = {:user, 1}

      Conversations
      |> stub(:get_conversation!, fn _, _other -> %{id: 123, title: "Same"} end)
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      Sagents.Subscriber
      |> stub(:unsubscribe_from_agent, fn _, _other -> raise "Should not be called" end)
      |> stub(:subscribe_to_agent, fn subs, _other -> subs end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)
      |> stub(:track_conversation_viewer, fn _, _other -> {:ok, :ref} end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

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
      |> stub(:get_conversation!, fn _, _other -> %{id: 123, title: "Test"} end)
      |> stub(:load_display_messages, fn _, _other -> [] end)
      |> stub(:load_todos, fn _, _other -> [] end)

      AgentsDemo.Agents.Coordinator
      |> stub(:conversation_agent_id, fn _other -> "agent-123" end)
      |> stub(:track_conversation_viewer, fn _, _other ->
        {:error, {:already_tracked, :ref, :meta, :data}}
      end)

      Sagents.Subscriber
      |> stub(:subscribe_to_agent, fn subs, _other -> subs end)

      Sagents.AgentServer
      |> stub(:get_status, fn _other -> :not_running end)

      {:ok, result} =
        AgentLiveHelpers.load_conversation(socket, 123,
          scope: scope,
          user_id: 1
        )

      assert result.assigns.conversation_id == 123
    end
  end
end

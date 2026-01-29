defmodule AgentsDemoWeb.ChatLive do
  use AgentsDemoWeb, :live_view
  import AgentsDemoWeb.ChatComponents

  require Logger

  alias Sagents.AgentServer
  alias Sagents.FileSystemServer
  alias LangChain.Message
  alias LangChain.MessageDelta
  alias AgentsDemo.Conversations
  alias AgentsDemo.Agents.Coordinator
  alias AgentsDemo.Agents.DemoSetup

  @impl true
  def mount(_params, _session, socket) do
    # Start user's filesystem when they log in
    # Filesystem runs independently of conversations and survives across sessions
    user_id = socket.assigns.current_scope.user.id

    filesystem_scope =
      case DemoSetup.ensure_user_filesystem(user_id) do
        {:ok, fs_scope} ->
          # Subscribe to filesystem changes for real-time updates
          if connected?(socket) do
            FileSystemServer.subscribe(fs_scope)
          end

          fs_scope

        {:error, :supervisor_not_ready} ->
          Logger.debug("FileSystemSupervisor not available - filesystem features disabled")
          nil

        {:error, reason} ->
          Logger.warning("Failed to start user filesystem: #{inspect(reason)}")
          nil
      end

    # Get timezone from LiveSocket params (sent from browser)
    # This is only available when the socket is connected
    timezone =
      if connected?(socket) do
        get_connect_params(socket)["timezone"] || "UTC"
      else
        "UTC"
      end

    # Determine debug mode based on user preference
    # For demo: default to false, allow toggle
    # In production: could check user.role or permissions
    debug_mode = false

    # For new conversations, agent_id will be set when conversation is created
    {:ok,
     socket
     |> stream(:messages, [])
     |> stream(:conversation_list, [])
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:thread_id, nil)
     |> assign(:conversation, nil)
     |> assign(:conversation_id, nil)
     |> assign(:agent_id, nil)
     |> assign(:filesystem_scope, filesystem_scope)
     |> assign(:timezone, timezone)
     |> assign(:todos, [])
     |> assign_filesystem_files()
     |> assign(:sidebar_collapsed, false)
     |> assign(:sidebar_active_tab, "tasks")
     |> assign(:selected_sub_agent, nil)
     |> assign(:selected_file, nil)
     |> assign(:selected_file_path, nil)
     |> assign(:selected_file_content, nil)
     |> assign(:file_view_mode, :rendered)
     |> assign(:is_thread_history_open, false)
     |> assign(:has_messages, false)
     |> assign(:streaming_delta, nil)
     |> assign(:agent_status, :idle)
     |> assign(:pending_tools, [])
     |> assign(:interrupt_data, nil)
     |> assign(:conversations_loaded, 0)
     |> assign(:has_more_conversations, true)
     |> assign(:has_conversations, false)
     |> assign(:page_title, "Agents Demo")
     |> assign(:debug_mode, debug_mode)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    conversation_id = params["conversation_id"]
    previous_conversation_id = socket.assigns.conversation_id

    socket =
      cond do
        # Load conversation if conversation_id is present and different from current
        conversation_id && conversation_id != previous_conversation_id ->
          # Untrack presence from previous conversation if connected
          if connected?(socket) && previous_conversation_id do
            user_id = socket.assigns.current_scope.user.id
            Coordinator.untrack_conversation_viewer(previous_conversation_id, user_id, self())
            Logger.debug("Untracked presence from conversation #{previous_conversation_id}")
          end

          socket
          |> load_conversation(conversation_id)
          |> update_conversation_selection(previous_conversation_id, conversation_id)

        # If no conversation_id in URL, reset to fresh state
        is_nil(conversation_id) && previous_conversation_id ->
          # Untrack presence when going back to empty state
          if connected?(socket) do
            user_id = socket.assigns.current_scope.user.id
            Coordinator.untrack_conversation_viewer(previous_conversation_id, user_id, self())
            Logger.debug("Untracked presence from conversation #{previous_conversation_id}")
          end

          reset_conversation_state(socket)

        # No change needed
        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => message_text}, socket) do
    message_text = String.trim(message_text)

    if message_text == "" or socket.assigns.loading do
      {:noreply, socket}
    else
      # Create conversation if this is the first message
      socket =
        case socket.assigns.conversation_id do
          nil ->
            create_new_conversation(socket, message_text)

          _id ->
            socket
        end

      conversation_id = socket.assigns.conversation_id
      filesystem_scope = socket.assigns.filesystem_scope
      timezone = socket.assigns.timezone

      # Ensure agent is running (seamless start if not)
      # Coordinator.start_conversation_session is idempotent
      case Coordinator.start_conversation_session(conversation_id,
             scope: filesystem_scope,
             timezone: timezone
           ) do
        {:ok, session} ->
          # Create LangChain Message
          langchain_message = Message.new_user!(message_text)

          # Add message to AgentServer (will save and broadcast via PubSub)
          # (Subscription already active from load_conversation)
          case AgentServer.add_message(session.agent_id, langchain_message) do
            :ok ->
              Logger.info("Agent execution started")

              {:noreply,
               socket
               |> assign(:input, "")
               |> assign(:loading, true)}

            # Note: No stream_insert here!
            # Display happens when we receive {:display_message_saved, msg} event

            {:error, reason} ->
              Logger.error("Failed to execute agent: #{inspect(reason)}")

              {:noreply,
               socket
               |> assign(:loading, false)
               |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
          end

        {:error, reason} ->
          Logger.error("Failed to ensure agent running: #{inspect(reason)}")

          {:noreply,
           socket
           |> put_flash(:error, "Failed to start agent session: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("cancel_agent", _params, socket) do
    Logger.info("User requested to cancel agent execution")

    case AgentServer.cancel(socket.assigns.agent_id) do
      :ok ->
        # The cancellation message will be created when we receive the
        # {:status_changed, :cancelled, nil} event from AgentServer
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to cancel agent: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to cancel agent: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("update_input", %{"message" => message}, socket) do
    {:noreply, assign(socket, :input, message)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_event("new_thread", _params, socket) do
    previous_conversation_id = socket.assigns[:conversation_id]

    # Unsubscribe and untrack presence from current conversation if any
    if previous_conversation_id do
      :ok = Coordinator.unsubscribe_from_conversation(previous_conversation_id)

      # Untrack presence BEFORE modifying socket assigns so AgentServer
      # sees viewer count drop to 0 and can trigger smart shutdown
      if connected?(socket) do
        user_id = socket.assigns.current_scope.user.id
        Coordinator.untrack_conversation_viewer(previous_conversation_id, user_id, self())
      end
    end

    socket =
      socket
      |> assign(:conversation, nil)
      |> assign(:conversation_id, nil)
      |> assign(:agent_id, nil)
      |> assign(:page_title, "Agents Demo")
      |> assign(:agent_status, :idle)
      |> assign(:loading, false)
      |> assign(:todos, [])
      |> stream(:messages, [], reset: true)
      |> assign(:has_messages, false)
      |> assign(:selected_sub_agent, nil)
      |> reset_conversation_in_stream(previous_conversation_id)

    {:noreply,
     socket
     |> push_patch(to: ~p"/chat")
     |> put_flash(:info, "New conversation started")}
  end

  @impl true
  def handle_event("toggle_thread_history", _params, socket) do
    is_opening = !socket.assigns.is_thread_history_open

    socket =
      if is_opening do
        # When opening, reset and reload the stream to ensure items render
        scope = socket.assigns.current_scope
        conversations = Conversations.list_conversations(scope, limit: 20, offset: 0)

        loaded_count = length(conversations)

        socket
        |> assign(:is_thread_history_open, true)
        |> stream(:conversation_list, conversations, reset: true)
        |> assign(:conversations_loaded, loaded_count)
        |> assign(:has_more_conversations, loaded_count == 20)
        |> assign(:has_conversations, loaded_count > 0)
      else
        assign(socket, :is_thread_history_open, false)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :sidebar_active_tab, tab)}
  end

  @impl true
  def handle_event("view_file", %{"path" => path}, socket) do
    result =
      if socket.assigns.filesystem_scope do
        FileSystemServer.read_file(socket.assigns.filesystem_scope, path)
      else
        {:error, :no_filesystem}
      end

    case result do
      {:ok, content} ->
        {:noreply,
         socket
         |> assign(:selected_file_path, path)
         |> assign(:selected_file_content, content)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:selected_file_path, path)
         |> assign(:selected_file_content, "Error: Could not read file")}
    end
  end

  @impl true
  def handle_event("close_file_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_file_path, nil)
     |> assign(:selected_file_content, nil)
     |> assign(:file_view_mode, :rendered)}
  end

  @impl true
  def handle_event("toggle_file_view_mode", _params, socket) do
    new_mode = if socket.assigns.file_view_mode == :rendered, do: :raw, else: :rendered
    {:noreply, assign(socket, :file_view_mode, new_mode)}
  end

  @impl true
  def handle_event("load_more_conversations", _params, socket) do
    # Only load more if there are potentially more conversations
    if socket.assigns.has_more_conversations do
      scope = socket.assigns.current_scope
      offset = socket.assigns.conversations_loaded

      new_conversations = Conversations.list_conversations(scope, limit: 20, offset: offset)

      {:noreply,
       socket
       |> stream(:conversation_list, new_conversations, at: -1)
       |> assign(:conversations_loaded, offset + length(new_conversations))
       |> assign(:has_more_conversations, length(new_conversations) == 20)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("load_conversation", %{"id" => conversation_id}, socket) do
    # Navigate to the selected conversation
    {:noreply, push_patch(socket, to: ~p"/chat?conversation_id=#{conversation_id}")}
  end

  @impl true
  def handle_event("delete_conversation", %{"id" => conversation_id}, socket) do
    scope = socket.assigns.current_scope
    is_current = conversation_id == socket.assigns.conversation_id

    # Get conversation for logging and flash message
    conversation = Conversations.get_conversation!(scope, conversation_id)

    case Conversations.delete_conversation(scope, conversation_id) do
      {:ok, _deleted} ->
        Logger.info("Deleted conversation #{conversation_id}")

        socket =
          socket
          # Remove from stream
          |> stream_delete(:conversation_list, conversation)
          # Update counts
          |> assign(:conversations_loaded, socket.assigns.conversations_loaded - 1)
          |> assign(:has_conversations, socket.assigns.conversations_loaded > 0)

        # If this was the active conversation, reset to new conversation state
        socket =
          if is_current do
            socket
            |> reset_conversation_state()
            |> put_flash(:info, "Current conversation deleted. Starting new conversation.")
          else
            put_flash(
              socket,
              :info,
              "Conversation \"#{conversation.title}\" deleted successfully"
            )
          end

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to delete conversation: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to delete conversation")}
    end
  rescue
    Ecto.NoResultsError ->
      Logger.warning("Attempted to delete non-existent conversation #{conversation_id}")
      {:noreply, put_flash(socket, :error, "Conversation not found")}
  end

  @impl true
  def handle_event("approve_tool", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    pending_tools = socket.assigns.pending_tools

    # Real mode: approve just this one tool
    decisions = [%{type: :approve}]
    # Remove the approved tool from pending list
    remaining_tools = List.delete_at(pending_tools, index)

    Logger.info("Approving tool at index #{index}")
    Logger.debug("Decision: #{inspect(decisions)}")

    # Resume the agent with the decision for just this tool
    case AgentServer.resume(socket.assigns.agent_id, decisions) do
      :ok ->
        {:noreply,
         socket
         |> assign(:agent_status, :running)
         |> assign(:loading, true)
         |> assign(:pending_tools, remaining_tools)
         |> assign(:interrupt_data, nil)
         |> put_flash(:info, "Tool approved - agent resuming")}

      {:error, reason} ->
        Logger.error("Failed to resume agent: #{inspect(reason)}")
        error_msg = "Failed to resume agent: #{inspect(reason)}"
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("reject_tool", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    pending_tools = socket.assigns.pending_tools

    # Real mode: reject just this one tool
    decisions = [%{type: :reject}]
    # Remove the approved tool from pending list
    remaining_tools = List.delete_at(pending_tools, index)

    Logger.info("Rejecting tool at index #{index}")
    Logger.debug("Decision: #{inspect(decisions)}")

    # Resume the agent with the decision for just this tool
    case AgentServer.resume(socket.assigns.agent_id, decisions) do
      :ok ->
        {:noreply,
         socket
         |> assign(:agent_status, :running)
         |> assign(:loading, true)
         |> assign(:pending_tools, remaining_tools)
         |> assign(:interrupt_data, nil)
         |> put_flash(:info, "Tool rejected - agent resuming")}

      {:error, reason} ->
        Logger.error("Failed to resume agent: #{inspect(reason)}")
        error_msg = "Failed to resume agent: #{inspect(reason)}"
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @impl true
  def handle_event("toggle_debug_mode", _params, socket) do
    # Toggle debug mode (per-viewer preference)
    new_debug_mode = !socket.assigns.debug_mode

    socket = assign(socket, :debug_mode, new_debug_mode)

    # Re-render all existing messages with the new debug mode
    # We need to reload them from the database to force a re-render
    socket =
      if socket.assigns.conversation_id do
        stream(
          socket,
          :messages,
          AgentsDemo.Conversations.load_display_messages(socket.assigns.conversation_id),
          reset: true
        )
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
    Logger.info("Agent is running")
    {:noreply, assign(socket, :agent_status, :running)}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :idle, _data}}, socket) do
    Logger.info("Agent returned to idle state (execution completed)")

    # Persist agent state after successful completion
    persist_agent_state(socket, "on_completion")

    # Don't create messages here - they should be added via :llm_message and :tool_response handlers
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :idle)
     |> assign_filesystem_files()}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :cancelled, _data}}, socket) do
    Logger.info("Agent execution was cancelled")

    # Persist cancellation message to database and display it
    cancellation_text = "_Agent execution cancelled by user. Partial response discarded._"

    cancellation_message =
      if socket.assigns.conversation_id do
        # Persist to database
        case Conversations.append_text_message(
               socket.assigns.conversation_id,
               "assistant",
               cancellation_text
             ) do
          {:ok, display_msg} ->
            display_msg

          {:error, reason} ->
            Logger.error("Failed to persist cancellation message: #{inspect(reason)}")
            # Create fallback in-memory message
            %{
              id: generate_id(),
              message_type: :assistant,
              content_type: "text",
              content: %{"text" => cancellation_text},
              timestamp: DateTime.utc_now()
            }
        end
      else
        # No conversation yet - create in-memory message
        %{
          id: generate_id(),
          message_type: :assistant,
          content_type: "text",
          content: %{"text" => cancellation_text},
          timestamp: DateTime.utc_now()
        }
      end

    # Note: We do NOT persist agent state after cancellation because the state
    # may be in an inconsistent/incomplete state after the task was brutally killed

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :cancelled)
     |> assign(:streaming_delta, nil)
     |> stream_insert(:messages, cancellation_message)
     |> push_event("scroll-to-bottom", %{})
     |> assign_filesystem_files()}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :interrupted, interrupt_data}}, socket) do
    Logger.info("Agent execution interrupted - awaiting human approval")
    Logger.debug("Interrupt data: #{inspect(interrupt_data)}")

    # Extract action_requests (pending tool calls needing approval)
    action_requests = Map.get(interrupt_data, :action_requests, [])

    # Persist agent state to preserve context including the interrupt state
    persist_agent_state(socket, "on_interrupt")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :interrupted)
     |> assign(:pending_tools, action_requests)
     |> assign(:interrupt_data, interrupt_data)}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :error, reason}}, socket) do
    Logger.error("Agent execution failed: #{inspect(reason)}")

    error_display =
      case reason do
        %LangChain.LangChainError{} = error ->
          error.message

        other ->
          inspect(other)
      end

    # Persist error message to database and display it
    error_text = "Sorry, I encountered an error: #{error_display}"

    error_message =
      if socket.assigns.conversation_id do
        # Persist to database
        case Conversations.append_text_message(
               socket.assigns.conversation_id,
               "assistant",
               error_text
             ) do
          {:ok, display_msg} ->
            display_msg

          {:error, persist_reason} ->
            Logger.error("Failed to persist error message: #{inspect(persist_reason)}")
            # Create fallback in-memory message
            %{
              id: generate_id(),
              message_type: :assistant,
              content_type: "text",
              content: %{"text" => error_text},
              timestamp: DateTime.utc_now()
            }
        end
      else
        # No conversation yet - create in-memory message
        %{
          id: generate_id(),
          message_type: :assistant,
          content_type: "text",
          content: %{"text" => error_text},
          timestamp: DateTime.utc_now()
        }
      end

    # Persist agent state to preserve context up to the error
    persist_agent_state(socket, "on_error")

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :error)
     |> stream_insert(:messages, error_message)}
  end

  @impl true
  def handle_info({:agent, {:todos_updated, todos}}, socket) do
    Logger.debug("TODOs updated: #{length(todos)} items")
    {:noreply, assign(socket, :todos, todos)}
  end

  @impl true
  def handle_info({:agent, {:llm_deltas, deltas}}, socket) do
    # Append deltas to current streaming message
    socket =
      socket
      |> update_streaming_message(deltas)
      |> push_event("scroll-to-bottom", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent, {:llm_message, _message}}, socket) do
    # Complete message received - clear streaming state
    # This event signals that message processing is complete (separate from display)
    Logger.info("Complete LLM message received")

    {:noreply,
     socket
     |> assign(:streaming_delta, nil)
     |> assign(:loading, false)}

    # Note: No persistence, no UI update here!
    # Messages already saved and displayed via {:display_message_saved, msg} events
  end

  @impl true
  def handle_info({:agent, {:display_message_saved, display_msg}}, socket) do
    {:noreply,
     socket
     |> assign(:has_messages, true)
     |> stream_insert(:messages, display_msg)
     |> push_event("scroll-to-bottom", %{})}
  end

  @impl true
  def handle_info({:agent, {:llm_token_usage, usage}}, socket) do
    # Optional: Display token usage stats
    Logger.debug("Token usage: #{inspect(usage)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent, {:conversation_title_generated, new_title, agent_id}}, socket) do
    # Verify this is for our agent and we have a current conversation
    if agent_id == socket.assigns.agent_id && socket.assigns.conversation do
      # Update database
      case Conversations.update_conversation(socket.assigns.conversation, %{title: new_title}) do
        {:ok, updated_conversation} ->
          Logger.info("Updated conversation title to: #{new_title}")

          # Persist the agent state now that the title is in metadata
          state_data = AgentServer.export_state(socket.assigns.agent_id)

          case Conversations.save_agent_state(socket.assigns.conversation_id, state_data) do
            {:ok, _} ->
              Logger.debug(
                "Persisted agent state with title metadata for conversation #{socket.assigns.conversation_id}"
              )

            {:error, reason} ->
              Logger.error(
                "Failed to persist agent state after title generation: #{inspect(reason)}"
              )
          end

          # Build page title from new title
          page_title =
            if String.length(new_title) > 60 do
              truncated = String.slice(new_title, 0, 60)
              "#{truncated}... - Agents Demo"
            else
              "#{new_title} - Agents Demo"
            end

          socket =
            socket
            |> assign(:conversation, updated_conversation)
            |> assign(:page_title, page_title)

          # If thread history is open, update the conversation in the stream
          socket =
            if socket.assigns.is_thread_history_open do
              stream_insert(socket, :conversation_list, updated_conversation)
            else
              socket
            end

          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Failed to update conversation title: #{inspect(reason)}")
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:agent, {:agent_shutdown, shutdown_data}}, socket) do
    Logger.info("Agent #{shutdown_data.agent_id} shutting down: #{shutdown_data.reason}")

    # Clear the agent_id since the agent is no longer running
    # The next interaction will restart the agent via Coordinator
    {:noreply, assign(socket, :agent_id, nil)}
  end

  @impl true
  def handle_info({:file_system, {event_type, path}}, socket) do
    Logger.debug("FileSystem event #{event_type}: #{path}")
    {:noreply, assign_filesystem_files(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    # Ignore unknown messages
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    # PubSub subscriptions and Presence tracking are automatically cleaned up
    # when the LiveView process terminates - no manual cleanup needed

    # Note: We don't call Coordinator.stop_conversation_session/1 here
    # because other tabs/users might still be using the conversation.
    # The agent will shutdown based on:
    # 1. Presence tracking (if idle with no viewers)
    # 2. Inactivity timeout (10 minutes by default, as fallback)

    :ok
  end

  # Load conversation from database
  defp load_conversation(socket, conversation_id) do
    scope = socket.assigns.current_scope

    # Unsubscribe from previous conversation if switching conversations
    if connected?(socket) && socket.assigns[:conversation_id] &&
         socket.assigns.conversation_id != conversation_id do
      :ok = Coordinator.unsubscribe_from_conversation(socket.assigns.conversation_id)
      Logger.debug("Unsubscribed from previous conversation #{socket.assigns.conversation_id}")
    end

    conversation = Conversations.get_conversation!(scope, conversation_id)
    agent_id = Coordinator.conversation_agent_id(conversation_id)

    # Subscribe to agent events (works even if agent not running!)
    # Using ensure_* versions - idempotent, safe if user clicks same conversation multiple times
    if connected?(socket) do
      :ok = Coordinator.ensure_subscribed_to_conversation(conversation_id)
      Logger.debug("Ensured subscription to agent events for conversation #{conversation_id}")

      # Track presence - this enables smart agent shutdown
      user_id = socket.assigns.current_scope.user.id

      case Coordinator.track_conversation_viewer(conversation_id, user_id, self()) do
        {:ok, _ref} ->
          Logger.debug("Tracking presence for conversation #{conversation_id}, user #{user_id}")

        {:error, {:already_tracked, _, _, _}} ->
          Logger.debug(
            "Already tracking presence for conversation #{conversation_id}, user #{user_id}"
          )

        {:error, reason} ->
          Logger.warning("Failed to track presence: #{inspect(reason)}")
      end
    end

    # Load display messages for UI (no agent needed)
    display_messages = Conversations.load_display_messages(conversation_id)
    has_messages = !Enum.empty?(display_messages)

    # Load saved TODOs from database (no agent needed)
    # This shows historical TODOs immediately without starting the agent
    saved_todos = Conversations.load_todos(conversation_id)

    # Build page title from conversation title
    page_title =
      if conversation.title && conversation.title != "" do
        # Truncate long titles for page title
        truncated_title = String.slice(conversation.title, 0, 60)

        if String.length(conversation.title) > 60 do
          "#{truncated_title}... - Agents Demo"
        else
          "#{truncated_title} - Agents Demo"
        end
      else
        "Conversation - Agents Demo"
      end

    socket
    |> assign(:conversation, conversation)
    |> assign(:conversation_id, conversation_id)
    |> assign(:agent_id, agent_id)
    |> assign(:page_title, page_title)
    |> assign(:todos, saved_todos)
    |> stream(:messages, display_messages, reset: true)
    |> assign(:has_messages, has_messages)
    # Scroll to bottom when loading conversation
    |> push_event("scroll-to-bottom", %{})
  rescue
    Ecto.NoResultsError ->
      socket
      |> put_flash(:error, "Conversation not found")
      |> push_navigate(to: ~p"/chat")
  end

  # Reset to fresh conversation state
  defp reset_conversation_state(socket) do
    # Unsubscribe from current conversation if any
    if socket.assigns[:conversation_id] do
      :ok = Coordinator.unsubscribe_from_conversation(socket.assigns.conversation_id)
    end

    # Note: Presence tracking is automatically cleaned up when the LiveView process
    # terminates - no manual cleanup needed

    socket
    |> assign(:conversation, nil)
    |> assign(:conversation_id, nil)
    |> assign(:agent_id, nil)
    |> assign(:page_title, "Agents Demo")
    |> assign(:todos, [])
    |> stream(:messages, [], reset: true)
    |> assign(:has_messages, false)
  end

  # Update conversation selection in the stream to reflect active state
  # This re-inserts both the previous and new conversation items so they re-render
  # with the updated @conversation_id assign, updating the active styling
  defp update_conversation_selection(socket, previous_id, new_id) do
    socket
    |> reset_conversation_in_stream(previous_id)
    |> reset_conversation_in_stream(new_id)
  end

  # Re-insert a conversation into the stream to trigger re-render with updated active state
  # Used when switching conversations or starting a new thread
  defp reset_conversation_in_stream(socket, nil), do: socket

  defp reset_conversation_in_stream(socket, conversation_id) do
    if socket.assigns.is_thread_history_open do
      scope = socket.assigns.current_scope

      case Conversations.get_conversation(scope, conversation_id) do
        {:ok, conversation} ->
          stream_insert(socket, :conversation_list, conversation)

        {:error, :not_found} ->
          socket
      end
    else
      socket
    end
  end

  # Create new conversation in database
  defp create_new_conversation(socket, first_message_text) do
    scope = socket.assigns.current_scope

    # Generate title from first message (truncate at 60 chars)
    title = String.slice(first_message_text, 0, 60)

    case Conversations.create_conversation(scope, %{
           title: title,
           metadata: %{"version" => 1}
         }) do
      {:ok, conversation} ->
        Logger.info("Created new conversation: #{conversation.id}")

        agent_id = Coordinator.conversation_agent_id(conversation.id)

        # Subscribe to agent events (works even if agent not running!)
        # Using ensure_* versions - idempotent, safe to call multiple times
        if connected?(socket) do
          :ok = Coordinator.ensure_subscribed_to_conversation(conversation.id)
          Logger.debug("Ensured subscription to agent events for conversation #{conversation.id}")

          # Track presence - this enables smart agent shutdown
          user_id = socket.assigns.current_scope.user.id
          {:ok, _ref} = Coordinator.track_conversation_viewer(conversation.id, user_id, self())
          Logger.debug("Tracking presence for conversation #{conversation.id}, user #{user_id}")
        end

        socket =
          socket
          |> assign(:conversation, conversation)
          |> assign(:conversation_id, conversation.id)
          |> assign(:agent_id, agent_id)
          |> assign(:page_title, "New Conversation - Agents Demo")
          |> push_patch(to: ~p"/chat?conversation_id=#{conversation.id}")

        # If thread history is open, insert the new conversation at the top of the list
        socket =
          if socket.assigns.is_thread_history_open do
            socket
            |> stream_insert(:conversation_list, conversation, at: 0)
            |> assign(:has_conversations, true)
          else
            socket
          end

        socket

      {:error, changeset} ->
        Logger.error("Failed to create conversation: #{inspect(changeset)}")

        socket
        |> put_flash(:error, "Failed to create conversation")
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # Helper to persist agent state to database
  defp persist_agent_state(socket, context_label) do
    if socket.assigns[:conversation_id] && socket.assigns[:agent_id] do
      try do
        state_data = AgentServer.export_state(socket.assigns.agent_id)

        case Conversations.save_agent_state(socket.assigns.conversation_id, state_data) do
          {:ok, _} ->
            Logger.info(
              "Persisted agent state for conversation #{socket.assigns.conversation_id} (#{context_label})"
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to persist agent state (#{context_label}): #{inspect(reason)}")
            {:error, reason}
        end
      rescue
        error ->
          Logger.error(
            "Exception while persisting agent state (#{context_label}): #{inspect(error)}"
          )

          {:error, error}
      end
    else
      Logger.debug(
        "Skipping state persistence - no conversation_id or agent_id (#{context_label})"
      )

      :ok
    end
  end

  defp update_streaming_message(socket, deltas) do
    # Merge deltas into the accumulated streaming_delta
    current_delta = socket.assigns.streaming_delta
    updated_delta = MessageDelta.merge_deltas(current_delta, deltas)

    assign(socket, :streaming_delta, updated_delta)
  end

  defp assign_filesystem_files(socket) do
    # Convert to a map of path => %{type: :file, directory: virtual_dir}
    files =
      socket.assigns[:filesystem_scope]
      |> FileSystemServer.list_files()
      |> Enum.map(fn path ->
        # Extract directory information
        directory =
          path
          |> Path.dirname()
          |> case do
            "/" -> "Root"
            dir -> dir
          end

        {path, %{type: :file, directory: directory}}
      end)
      |> Enum.into(%{})

    assign(socket, :files, files)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen bg-[var(--color-surface)] overflow-hidden">
      <div class="flex-shrink-0">
        <.tasks_files_sidebar
          todos={@todos}
          files={@files}
          collapsed={@sidebar_collapsed}
          active_tab={@sidebar_active_tab}
        />
      </div>

      <div class="flex flex-1 min-w-0 relative">
        <.chat_interface
          streams={@streams}
          has_messages={@has_messages}
          input={@input}
          loading={@loading}
          thread_id={@thread_id}
          is_thread_history_open={@is_thread_history_open}
          streaming_delta={@streaming_delta}
          agent_status={@agent_status}
          pending_tools={@pending_tools}
          current_scope={@current_scope}
          conversation_id={@conversation_id}
          has_more_conversations={@has_more_conversations}
          has_conversations={@has_conversations}
          debug_mode={@debug_mode}
        />
      </div>

      <%= if @selected_file_path do %>
        <.file_viewer_modal
          path={@selected_file_path}
          content={@selected_file_content}
          view_mode={@file_view_mode}
        />
      <% end %>
    </div>
    """
  end
end

defmodule AgentsDemoWeb.ChatLive do
  use AgentsDemoWeb, :live_view
  import AgentsDemoWeb.ChatComponents

  require Logger

  alias Sagents.AgentServer
  alias Sagents.FileSystemServer
  alias LangChain.Message
  alias AgentsDemo.Conversations
  alias AgentsDemo.Agents.Coordinator
  alias AgentsDemo.Agents.DemoSetup
  alias AgentsDemoWeb.AgentLiveHelpers

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
     # Initialize all agent-related state with helper
     |> AgentLiveHelpers.init_agent_state()
     # Initialize conversation list stream (app-specific UI state)
     |> stream(:conversation_list, [])
     # Application-specific assigns
     |> assign(:input, "")
     |> assign(:filesystem_scope, filesystem_scope)
     |> assign(:timezone, timezone)
     |> assign_filesystem_files()
     |> assign(:sidebar_collapsed, false)
     |> assign(:sidebar_active_tab, "tasks")
     |> assign(:selected_sub_agent, nil)
     |> assign(:selected_file, nil)
     |> assign(:selected_file_path, nil)
     |> assign(:selected_file_content, nil)
     |> assign(:file_view_mode, :rendered)
     |> assign(:is_thread_history_open, false)
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
            Coordinator.untrack_conversation_viewer(previous_conversation_id, user_id)
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
            Coordinator.untrack_conversation_viewer(previous_conversation_id, user_id)
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

    # Untrack presence BEFORE resetting state so AgentServer
    # sees viewer count drop to 0 and can trigger smart shutdown
    if previous_conversation_id && connected?(socket) do
      user_id = socket.assigns.current_scope.user.id
      Coordinator.untrack_conversation_viewer(previous_conversation_id, user_id)
    end

    socket =
      socket
      |> AgentLiveHelpers.reset_conversation()
      |> assign(:page_title, "Agents Demo")
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
  def handle_event("wake_agent", _params, socket) do
    conversation_id = socket.assigns.conversation_id
    filesystem_scope = socket.assigns.filesystem_scope
    timezone = socket.assigns.timezone

    Logger.info("Waking agent for conversation #{conversation_id} (debug mode)")

    # Start or ensure agent session is running (idempotent operation)
    # This loads the saved agent state into memory without executing
    # Once started, the agent will broadcast status changes and the button will disappear
    case Coordinator.start_conversation_session(conversation_id,
           scope: filesystem_scope,
           timezone: timezone
         ) do
      {:ok, session} ->
        Logger.info("Agent woken successfully: #{session.agent_id}")
        {:noreply, put_flash(socket, :info, "Agent activated and ready for debugging")}

      {:error, reason} ->
        Logger.error("Failed to wake agent: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to activate agent: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
    Logger.info("Agent is running")
    {:noreply, AgentLiveHelpers.handle_status_running(socket)}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :idle, _data}}, socket) do
    Logger.info("Agent returned to idle state (execution completed)")
    {:noreply, AgentLiveHelpers.handle_status_idle(socket)}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :cancelled, _data}}, socket) do
    Logger.info("Agent execution was cancelled")

    {:noreply,
     socket
     |> AgentLiveHelpers.handle_status_cancelled()
     |> push_event("scroll-to-bottom", %{})}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :interrupted, interrupt_data}}, socket) do
    Logger.info("Agent execution interrupted - awaiting human approval")
    Logger.debug("Interrupt data: #{inspect(interrupt_data)}")

    {:noreply, AgentLiveHelpers.handle_status_interrupted(socket, interrupt_data)}
  end

  @impl true
  def handle_info({:agent, {:status_changed, :error, reason}}, socket) do
    Logger.error("Agent execution failed: #{inspect(reason)}")
    {:noreply, AgentLiveHelpers.handle_status_error(socket, reason)}
  end

  @impl true
  def handle_info({:agent, {:todos_updated, todos}}, socket) do
    Logger.debug("TODOs updated: #{length(todos)} items")
    {:noreply, assign(socket, :todos, todos)}
  end

  @impl true
  def handle_info({:agent, {:llm_deltas, deltas}}, socket) do
    {:noreply,
     socket
     |> AgentLiveHelpers.handle_llm_deltas(deltas)
     |> push_event("scroll-to-bottom", %{})}
  end

  @impl true
  def handle_info({:agent, {:llm_message, _message}}, socket) do
    {:noreply, AgentLiveHelpers.handle_llm_message_complete(socket)}
  end

  @impl true
  def handle_info({:agent, {:display_message_saved, display_msg}}, socket) do
    {:noreply,
     socket
     |> AgentLiveHelpers.handle_display_message_saved(display_msg)
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
    Logger.info("Conversation title generated: #{new_title}")

    # Build page title from new title (application-specific UI concern)
    page_title =
      if String.length(new_title) > 60 do
        truncated = String.slice(new_title, 0, 60)
        "#{truncated}... - Agents Demo"
      else
        "#{new_title} - Agents Demo"
      end

    socket =
      socket
      |> AgentLiveHelpers.handle_conversation_title_generated(new_title, agent_id)
      |> assign(:page_title, page_title)

    # Update conversation list if thread history is open (application-specific UI)
    socket =
      if socket.assigns[:is_thread_history_open] && socket.assigns[:conversation] do
        stream_insert(socket, :conversation_list, socket.assigns.conversation)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent, {:agent_shutdown, shutdown_data}}, socket) do
    {:noreply, AgentLiveHelpers.handle_agent_shutdown(socket, shutdown_data)}
  end

  @impl true
  def handle_info({:agent, {:tool_call_identified, tool_info}}, socket) do
    {:noreply,
     socket
     |> AgentLiveHelpers.handle_tool_call_identified(tool_info)
     |> push_event("scroll-to-bottom", %{})}
  end

  @impl true
  def handle_info({:agent, {:tool_execution_update, status, tool_info}}, socket) do
    {:noreply,
     socket
     |> AgentLiveHelpers.handle_tool_execution_update(status, tool_info)
     |> push_event("scroll-to-bottom", %{})}
  end

  @impl true
  def handle_info({:agent, {:display_message_updated, updated_msg}}, socket) do
    {:noreply,
     socket
     |> AgentLiveHelpers.handle_display_message_updated(updated_msg)
     |> push_event("scroll-to-bottom", %{})}
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

  # Load conversation from database using helper
  defp load_conversation(socket, conversation_id) do
    scope = socket.assigns.current_scope
    user_id = socket.assigns.current_scope.user.id

    case AgentLiveHelpers.load_conversation(socket, conversation_id,
           scope: scope,
           user_id: user_id
         ) do
      {:ok, socket} ->
        # Build page title from conversation title (application-specific)
        page_title = build_page_title(socket.assigns.conversation)

        socket
        |> assign(:page_title, page_title)
        |> push_event("scroll-to-bottom", %{})

      {:error, socket} ->
        # Conversation not found - navigate to fresh state
        push_navigate(socket, to: ~p"/chat")
    end
  end

  # Build page title from conversation (application-specific formatting)
  defp build_page_title(conversation) do
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
  end

  # Reset to fresh conversation state using helper
  defp reset_conversation_state(socket) do
    socket
    |> AgentLiveHelpers.reset_conversation()
    |> assign(:page_title, "Agents Demo")
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
          {:ok, _ref} = Coordinator.track_conversation_viewer(conversation.id, user_id)
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

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end
end

defmodule AgentsDemoWeb.ChatLive do
  use AgentsDemoWeb, :live_view
  import AgentsDemoWeb.ChatComponents

  require Logger

  alias LangChain.Agents.AgentServer
  alias LangChain.Agents.FileSystemServer
  alias LangChain.Agents.Todo
  alias LangChain.Message
  alias LangChain.Message.ToolCall
  alias LangChain.Message.ToolResult
  alias LangChain.MessageDelta
  alias AgentsDemo.Conversations
  alias AgentsDemo.Conversations.DisplayMessage

  @agent_id "demo-agent-001"

  # TODO: Issues:
  #

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case AgentServer.subscribe(@agent_id) do
        :ok ->
          Logger.info("Subscribed to AgentServer for agent #{@agent_id}")

        {:error, reason} ->
          Logger.error("Failed to subscribe to AgentServer: #{inspect(reason)}")
      end
    end

    {:ok,
     socket
     |> stream(:messages, [])
     |> stream(:conversation_list, [])
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:thread_id, nil)
     |> assign(:conversation, nil)
     |> assign(:conversation_id, nil)
     |> assign(:todos, [])
     |> assign_filesystem_files()
     |> assign(:sidebar_collapsed, false)
     |> assign(:sidebar_active_tab, "tasks")
     |> assign(:selected_sub_agent, nil)
     |> assign(:selected_file, nil)
     |> assign(:selected_file_path, nil)
     |> assign(:selected_file_content, nil)
     |> assign(:is_thread_history_open, false)
     |> assign(:has_messages, false)
     |> assign(:streaming_delta, nil)
     |> assign(:agent_status, :idle)
     |> assign(:pending_tools, [])
     |> assign(:interrupt_data, nil)
     |> assign(:conversations_loaded, 0)
     |> assign(:has_more_conversations, true)
     |> assign(:has_conversations, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    conversation_id = params["conversation_id"]
    previous_conversation_id = socket.assigns.conversation_id

    socket =
      cond do
        # Load conversation if conversation_id is present and different from current
        conversation_id && conversation_id != previous_conversation_id ->
          socket
          |> load_conversation(conversation_id)
          |> update_conversation_selection(previous_conversation_id, conversation_id)

        # If no conversation_id in URL, reset to fresh state
        is_nil(conversation_id) && previous_conversation_id ->
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

      # Persist user message to database
      case persist_user_message(socket.assigns.conversation_id, message_text) do
        {:ok, display_msg} ->
          # Create LangChain Message
          langchain_message = Message.new_user!(message_text)

          # Add message to AgentServer and execute
          case AgentServer.add_message(@agent_id, langchain_message) do
            :ok ->
              Logger.info("Agent execution started")

              {:noreply,
               socket
               |> assign(:input, "")
               |> assign(:loading, true)
               |> assign(:has_messages, true)
               |> stream_insert(:messages, display_msg)
               |> push_event("scroll-to-bottom", %{})}

            {:error, reason} ->
              Logger.error("Failed to execute agent: #{inspect(reason)}")

              {:noreply,
               socket
               |> assign(:loading, false)
               |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
          end

        {:error, reason} ->
          Logger.error("Failed to persist user message: #{inspect(reason)}")

          {:noreply,
           socket
           |> put_flash(:error, "Failed to save message")}
      end
    end
  end

  @impl true
  def handle_event("cancel_agent", _params, socket) do
    Logger.info("User requested to cancel agent execution")

    case AgentServer.cancel(@agent_id) do
      :ok ->
        # Create a cancellation message to display in the chat
        cancellation_message = %{
          id: generate_id(),
          type: :assistant,
          content: "_Action was cancelled by user._",
          timestamp: DateTime.utc_now()
        }

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:agent_status, :completed)
         |> assign(:streaming_delta, nil)
         |> stream_insert(:messages, cancellation_message)
         |> push_event("scroll-to-bottom", %{})
         |> put_flash(:info, "Agent execution cancelled")}

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
    :ok = AgentServer.reset(@agent_id)

    {:noreply,
     socket
     |> assign(:conversation, nil)
     |> assign(:conversation_id, nil)
     |> stream(:messages, [], reset: true)
     |> assign(:has_messages, false)
     |> assign(:selected_sub_agent, nil)
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
  def handle_event("setup_demo_data", _params, socket) do
    # Create sample TODO items with different states for testing
    todos = [
      Todo.new!(%{content: "Initialize project setup", status: :completed}),
      Todo.new!(%{content: "Configure API endpoints", status: :in_progress}),
      Todo.new!(%{content: "Write integration tests", status: :pending}),
      Todo.new!(%{content: "Deploy to production", status: :pending})
    ]

    # Create sample messages with different types for testing
    # Include tool calls and tool results to test UI rendering
    tool_call_1 =
      ToolCall.new!(%{
        call_id: "call_abc123",
        name: "search_web",
        arguments: %{"query" => "Oslo attractions in Spring"}
      })

    tool_result_1 =
      ToolResult.new!(%{
        tool_call_id: "call_abc123",
        name: "search_web",
        content:
          "Found 5 top attractions: Vigeland Park, Oslo Opera House, Akershus Fortress, Viking Ship Museum, and the Royal Palace."
      })

    tool_call_2 =
      ToolCall.new!(%{
        call_id: "call_def456",
        name: "get_weather",
        arguments: %{"location" => "Oslo", "season" => "Spring"}
      })

    tool_result_2 =
      ToolResult.new!(%{
        tool_call_id: "call_def456",
        name: "get_weather",
        content:
          "Spring weather in Oslo: Average temperature 8-15°C, mild with occasional rain. Best time to visit is late April to May."
      })

    messages = [
      Message.new_user!("What sights should I see when I visit Oslo in the Spring?"),
      Message.new_assistant!(%{
        content: "Let me search for information about Oslo attractions and the Spring weather.",
        tool_calls: [tool_call_1, tool_call_2]
      }),
      Message.new_tool_result!(%{tool_results: [tool_result_1, tool_result_2]}),
      Message.new_assistant!(
        "Based on the search results, here are my top recommendations for visiting Oslo in Spring:\n\n1. **Vigeland Park** - Perfect for spring walks among 200+ sculptures\n2. **Oslo Opera House** - Iconic architecture with rooftop views\n3. **Akershus Fortress** - Medieval castle with harbor views\n4. **Viking Ship Museum** - Explore Norway's Viking heritage\n5. **Royal Palace** - Beautiful palace grounds ideal for spring strolls\n\nSpring is an excellent time to visit with temperatures ranging from 8-15°C. Late April to May offers the best weather with blooming flowers throughout the city!"
      )
    ]

    # Set TODOs and messages on the AgentServer
    # The existing PubSub handlers will update the UI
    with :ok <- AgentServer.set_todos(@agent_id, todos),
         :ok <- AgentServer.set_messages(@agent_id, messages) do
      Logger.info("Demo data (TODOs and messages) set successfully")
      {:noreply, socket}
    else
      {:error, reason} ->
        Logger.error("Failed to set demo data: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to set demo data")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :sidebar_active_tab, tab)}
  end

  @impl true
  def handle_event("view_file", %{"path" => path}, socket) do
    case FileSystemServer.read_file(@agent_id, path) do
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
     |> assign(:selected_file_content, nil)}
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
    case AgentServer.resume(@agent_id, decisions) do
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
    case AgentServer.resume(@agent_id, decisions) do
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
  def handle_info({:status_changed, :running, nil}, socket) do
    Logger.info("Agent is running")
    {:noreply, assign(socket, :agent_status, :running)}
  end

  @impl true
  def handle_info({:status_changed, :completed, _final_state}, socket) do
    Logger.info("Agent completed execution")

    # Don't create messages here - they should be added via :llm_message and :tool_response handlers
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :completed)
     |> assign_filesystem_files()}
  end

  @impl true
  def handle_info({:status_changed, :interrupted, interrupt_data}, socket) do
    Logger.info("Agent execution interrupted - awaiting human approval")
    Logger.debug("Interrupt data: #{inspect(interrupt_data)}")

    # Extract action_requests (pending tool calls needing approval)
    action_requests = Map.get(interrupt_data, :action_requests, [])

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :interrupted)
     |> assign(:pending_tools, action_requests)
     |> assign(:interrupt_data, interrupt_data)}
  end

  @impl true
  def handle_info({:status_changed, :error, reason}, socket) do
    Logger.error("Agent execution failed: #{inspect(reason)}")

    error_display =
      case reason do
        %LangChain.LangChainError{} = error ->
          error.message

        other ->
          inspect(other)
      end

    error_message = %{
      id: generate_id(),
      type: :assistant,
      content: "Sorry, I encountered an error: #{error_display}",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:agent_status, :error)
     |> stream_insert(:messages, error_message)}
  end

  @impl true
  def handle_info({:todos_updated, todos}, socket) do
    Logger.debug("TODOs updated: #{length(todos)} items")
    {:noreply, assign(socket, :todos, todos)}
  end

  @impl true
  def handle_info({:llm_deltas, deltas}, socket) do
    # Append deltas to current streaming message
    # deltas is a list, so we need to iterate through them
    socket =
      socket
      |> update_streaming_message(deltas)
      |> push_event("scroll-to-bottom", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:llm_message, message}, socket) do
    # Complete message received - finalize display
    Logger.info("Complete LLM message received")

    socket =
      socket
      |> finalize_streaming_message(message)
      |> assign(:loading, false)
      |> push_event("scroll-to-bottom", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:llm_token_usage, usage}, socket) do
    # Optional: Display token usage stats
    Logger.debug("Token usage: #{inspect(usage)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:conversation_title_generated, new_title, agent_id}, socket) do
    # Verify this is for our agent and we have a current conversation
    if agent_id == @agent_id && socket.assigns.conversation do
      # Update database
      case Conversations.update_conversation(socket.assigns.conversation, %{title: new_title}) do
        {:ok, updated_conversation} ->
          Logger.info("Updated conversation title to: #{new_title}")

          {:noreply,
           socket
           |> assign(:conversation, updated_conversation)}

        {:error, reason} ->
          Logger.error("Failed to update conversation title: #{inspect(reason)}")
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    # Ignore unknown messages
    {:noreply, socket}
  end

  # Load conversation from database
  defp load_conversation(socket, conversation_id) do
    scope = socket.assigns.current_scope

    conversation = Conversations.get_conversation!(scope, conversation_id)

    # Load display messages
    display_messages = Conversations.load_display_messages(conversation_id)

    # Restore agent state if it exists
    case Conversations.load_agent_state(conversation_id) do
      {:ok, state_data} ->
        AgentServer.restore_state(@agent_id, state_data)

      {:error, :not_found} ->
        # No saved state, fresh start
        :ok
    end

    socket
    |> assign(:conversation, conversation)
    |> assign(:conversation_id, conversation_id)
    |> stream(:messages, display_messages, reset: true)
    |> assign(:has_messages, length(display_messages) > 0)
  rescue
    Ecto.NoResultsError ->
      socket
      |> put_flash(:error, "Conversation not found")
      |> push_navigate(to: ~p"/chat")
  end

  # Reset to fresh conversation state
  defp reset_conversation_state(socket) do
    AgentServer.reset(@agent_id)

    socket
    |> assign(:conversation, nil)
    |> assign(:conversation_id, nil)
    |> stream(:messages, [], reset: true)
    |> assign(:has_messages, false)
  end

  # Update conversation selection in the stream to reflect active state
  # This re-inserts both the previous and new conversation items so they re-render
  # with the updated @conversation_id assign, updating the active styling
  defp update_conversation_selection(socket, previous_id, new_id) do
    scope = socket.assigns.current_scope

    # Only update if the history sidebar is open and has conversations
    if socket.assigns.is_thread_history_open && socket.assigns.has_conversations do
      # Re-insert previous conversation to clear its active state
      socket =
        if previous_id do
          try do
            prev_conversation = Conversations.get_conversation!(scope, previous_id)
            stream_insert(socket, :conversation_list, prev_conversation)
          rescue
            Ecto.NoResultsError ->
              # Previous conversation not found, skip it
              socket
          end
        else
          socket
        end

      # Re-insert new conversation to set its active state
      try do
        new_conversation = Conversations.get_conversation!(scope, new_id)
        stream_insert(socket, :conversation_list, new_conversation)
      rescue
        Ecto.NoResultsError ->
          # New conversation not found (shouldn't happen), skip it
          socket
      end
    else
      # History sidebar not open, no need to update stream
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

        socket
        |> assign(:conversation, conversation)
        |> assign(:conversation_id, conversation.id)
        |> push_patch(to: ~p"/chat?conversation_id=#{conversation.id}")

      {:error, changeset} ->
        Logger.error("Failed to create conversation: #{inspect(changeset)}")

        socket
        |> put_flash(:error, "Failed to create conversation")
    end
  end

  # Persist user message to database
  defp persist_user_message(conversation_id, message_text) do
    Conversations.append_text_message(conversation_id, "user", message_text)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp update_streaming_message(socket, deltas) do
    # Merge deltas into the accumulated streaming_delta
    current_delta = socket.assigns.streaming_delta
    updated_delta = MessageDelta.merge_deltas(current_delta, deltas)

    assign(socket, :streaming_delta, updated_delta)
  end

  defp finalize_streaming_message(socket, message) do
    conversation_id = socket.assigns.conversation_id

    # Extract both thinking and text content from message
    content_parts = extract_message_content_parts(message)

    # Log warning if no content - this shouldn't happen
    if Enum.empty?(content_parts) do
      Logger.warning(
        "Received empty message content. Message: #{inspect(message)}, " <>
          "Streaming delta: #{inspect(socket.assigns.streaming_delta)}"
      )
    end

    # Persist and display each content part
    socket =
      if not Enum.empty?(content_parts) do
        # Persist each content part to database if conversation exists
        display_msgs =
          if conversation_id do
            persist_content_parts(conversation_id, content_parts)
          else
            # No conversation yet - create in-memory messages
            create_in_memory_messages(content_parts, conversation_id)
          end

        # Insert all messages into the stream
        Enum.reduce(display_msgs, socket, fn msg, acc ->
          acc
          |> assign(:has_messages, true)
          |> stream_insert(:messages, msg)
        end)
      else
        # Empty content - don't persist or display
        socket
      end

    # Always clear streaming state
    assign(socket, :streaming_delta, nil)
  end

  # Extract content parts from Message struct
  # Returns a list of {type, content} tuples, e.g. [{:thinking, "..."}, {:text, "..."}]
  defp extract_message_content_parts(%Message{content: content}) when is_binary(content) do
    [{:text, content}]
  end

  defp extract_message_content_parts(%Message{content: content}) when is_list(content) do
    # Handle list of ContentPart structs - extract both thinking and text
    content
    |> Enum.filter(fn part -> part.type in [:thinking, :text] end)
    |> Enum.map(fn part -> {part.type, part.content} end)
    |> Enum.reject(fn {_type, content} -> is_nil(content) or content == "" end)
  end

  defp extract_message_content_parts(_), do: []

  # Persist content parts to database, returning list of DisplayMessage structs
  defp persist_content_parts(conversation_id, content_parts) do
    content_parts
    |> Enum.with_index()
    |> Enum.map(fn {{type, content}, _index} ->
      case type do
        :thinking ->
          case Conversations.append_thinking_message(conversation_id, content) do
            {:ok, msg} ->
              msg

            {:error, reason} ->
              Logger.error("Failed to persist thinking message: #{inspect(reason)}")
              create_fallback_message(conversation_id, type, content)
          end

        :text ->
          case Conversations.append_text_message(conversation_id, "assistant", content) do
            {:ok, msg} ->
              msg

            {:error, reason} ->
              Logger.error("Failed to persist text message: #{inspect(reason)}")
              create_fallback_message(conversation_id, type, content)
          end
      end
    end)
  end

  # Create in-memory messages when no conversation exists
  defp create_in_memory_messages(content_parts, conversation_id) do
    content_parts
    |> Enum.with_index()
    |> Enum.map(fn {{type, content}, _index} ->
      create_fallback_message(conversation_id, type, content)
    end)
  end

  # Create a fallback in-memory DisplayMessage
  defp create_fallback_message(conversation_id, type, content) do
    {content_type, message_type} =
      case type do
        :thinking -> {"thinking", "assistant"}
        :text -> {"text", "assistant"}
      end

    %DisplayMessage{
      id: Ecto.UUID.generate(),
      conversation_id: conversation_id,
      message_type: message_type,
      content_type: content_type,
      content: %{"text" => content},
      inserted_at: DateTime.utc_now()
    }
  end

  defp assign_filesystem_files(socket) do
    try do
      # Get all file paths from the FileSystemServer
      file_paths = FileSystemServer.list_files(@agent_id)

      # Convert to a map of path => %{type: :file, directory: virtual_dir}
      files =
        file_paths
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
    rescue
      _ ->
        # If FileSystemServer isn't available yet, return empty map
        assign(socket, :files, %{})
    end
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
        />
      </div>

      <%= if @selected_file_path do %>
        <.file_viewer_modal
          path={@selected_file_path}
          content={@selected_file_content}
        />
      <% end %>
    </div>
    """
  end
end

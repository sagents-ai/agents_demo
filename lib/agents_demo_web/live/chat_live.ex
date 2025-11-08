defmodule AgentsDemoWeb.ChatLive do
  use AgentsDemoWeb, :live_view
  import AgentsDemoWeb.ChatComponents

  require Logger

  alias LangChain.Agents.AgentServer
  alias LangChain.Agents.FileSystemServer
  alias LangChain.Agents.Todo
  alias LangChain.Message

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
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:thread_id, nil)
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
     |> assign(:streaming_content, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    thread_id = params["thread_id"]

    socket =
      if thread_id && thread_id != socket.assigns.thread_id do
        # Load thread state when thread_id changes
        load_thread(socket, thread_id)
      else
        socket
      end

    {:noreply, assign(socket, :thread_id, thread_id)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message_text}, socket) do
    message_text = String.trim(message_text)

    if message_text == "" or socket.assigns.loading do
      {:noreply, socket}
    else
      # Add user message immediately to UI
      user_message = %{
        id: generate_id(),
        type: :human,
        content: message_text,
        timestamp: DateTime.utc_now()
      }

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
           |> stream_insert(:messages, user_message)}

        {:error, reason} ->
          Logger.error("Failed to execute agent: #{inspect(reason)}")

          {:noreply,
           socket
           |> assign(:loading, false)
           |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")}
      end
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
     |> assign(:thread_id, nil)
     |> stream(:messages, [], reset: true)
     |> assign(:has_messages, false)
     #  |> assign(:todos, [])
     #  |> assign(:files, %{})
     |> assign(:selected_sub_agent, nil)
     |> push_patch(to: ~p"/chat")
     |> put_flash(:info, "New thread started")}
  end

  @impl true
  def handle_event("toggle_thread_history", _params, socket) do
    {:noreply, assign(socket, :is_thread_history_open, !socket.assigns.is_thread_history_open)}
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

    # Set TODOs on the AgentServer - the existing PubSub handlers will update the UI
    case AgentServer.set_todos(@agent_id, todos) do
      :ok ->
        Logger.info("Test TODOs set successfully")
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to set test TODOs: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to set test TODOs")}
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
  def handle_info({:status_changed, :running, nil}, socket) do
    Logger.info("Agent is running")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:status_changed, :completed, final_state}, socket) do
    Logger.info("Agent completed execution")

    # Extract the last assistant message from the state
    assistant_messages =
      final_state.messages
      |> Enum.reverse()
      |> Enum.find(fn msg -> msg.role == :assistant end)

    case assistant_messages do
      %Message{content: content} when is_binary(content) ->
        ai_message = %{
          id: generate_id(),
          type: :ai,
          content: content,
          timestamp: DateTime.utc_now()
        }

        # Update todos if they changed
        socket =
          if final_state.todos != socket.assigns.todos do
            assign(socket, :todos, final_state.todos)
          else
            socket
          end

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign_filesystem_files()
         |> stream_insert(:messages, ai_message)}

      _ ->
        Logger.warning("No assistant message found in completed state")

        {:noreply, assign(socket, :loading, false)}
    end
  end

  @impl true
  def handle_info({:status_changed, :error, reason}, socket) do
    Logger.error("Agent execution failed: #{inspect(reason)}")

    error_message = %{
      id: generate_id(),
      type: :ai,
      content: "Sorry, I encountered an error: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:loading, false)
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
    socket = update_streaming_message(socket, deltas)

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

    {:noreply, socket}
  end

  @impl true
  def handle_info({:llm_token_usage, usage}, socket) do
    # Optional: Display token usage stats
    Logger.debug("Token usage: #{inspect(usage)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:tool_response, message}, socket) do
    # Optional: Display tool execution results
    # This could be used to show "thinking" indicators
    Logger.debug("Tool response: #{inspect(message.content)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    # Ignore unknown messages
    {:noreply, socket}
  end

  defp load_thread(socket, _thread_id) do
    # TODO: Load thread state from storage/agent
    # For now, just return empty state
    socket
    |> stream(:messages, [], reset: true)
    |> assign(:has_messages, false)
    |> assign(:todos, [])
    |> assign(:files, %{})
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp update_streaming_message(socket, deltas) do
    # Extract content from delta
    content = extract_delta_content(delta)

    # Append to streaming_content
    current_content = socket.assigns.streaming_content || ""
    updated_content = current_content <> content

    assign(socket, :streaming_content, updated_content)
  end

  defp finalize_streaming_message(socket, message) do
    # Use the complete message from the LLM, ignore streaming_content
    # The message struct has the final, complete content
    ai_message = %{
      id: generate_id(),
      type: :ai,
      content: extract_message_content(message),
      timestamp: DateTime.utc_now()
    }

    socket
    |> assign(:streaming_content, nil)
    |> stream_insert(:messages, ai_message)
  end

  # Extract content from MessageDelta struct
  defp extract_delta_content(%{content: content}) when is_binary(content), do: content
  defp extract_delta_content(%{content: [%{text: text}]}) when is_binary(text), do: text

  defp extract_delta_content(%{content: content}) when is_list(content) do
    # Handle list of content blocks
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_delta_content(_), do: ""

  # Extract content from Message struct
  defp extract_message_content(%Message{content: content}) when is_binary(content), do: content

  defp extract_message_content(%Message{content: content}) when is_list(content) do
    # Handle list of content blocks
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_message_content(_), do: ""

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
          streaming_content={@streaming_content}
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

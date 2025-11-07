defmodule AgentsDemoWeb.ChatLive do
  use AgentsDemoWeb, :live_view

  require Logger

  alias LangChain.Agents.AgentServer
  alias LangChain.Agents.FileSystemServer
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
     |> assign(:has_messages, false)}
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
           |> assign(:loading, true)}

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
    # Note: This only clears the UI. The AgentServer still has its conversation history.
    # For a true "new thread", we'd need to reset the AgentServer's state, which would
    # require adding a reset API or restarting the AgentServer.
    {:noreply,
     socket
     |> assign(:thread_id, nil)
     |> stream(:messages, [], reset: true)
     |> assign(:has_messages, false)
     |> assign(:todos, [])
     |> assign(:files, %{})
     |> assign(:selected_sub_agent, nil)
     |> push_patch(to: ~p"/chat")}
  end

  @impl true
  def handle_event("toggle_thread_history", _params, socket) do
    {:noreply, assign(socket, :is_thread_history_open, !socket.assigns.is_thread_history_open)}
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
  def handle_info({:todo_created, todo}, socket) do
    Logger.info("Todo created: #{todo.content}")
    todos = socket.assigns.todos ++ [todo]
    {:noreply, assign(socket, :todos, todos)}
  end

  @impl true
  def handle_info({:todo_updated, todo}, socket) do
    Logger.info("Todo updated: #{todo.content}")

    todos =
      Enum.map(socket.assigns.todos, fn t ->
        if t.id == todo.id, do: todo, else: t
      end)

    {:noreply, assign(socket, :todos, todos)}
  end

  @impl true
  def handle_info({:todo_deleted, todo_id}, socket) do
    Logger.info("Todo deleted: #{todo_id}")
    todos = Enum.reject(socket.assigns.todos, fn t -> t.id == todo_id end)
    {:noreply, assign(socket, :todos, todos)}
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

  defp group_files_by_directory(files) do
    files
    |> Enum.group_by(fn {_path, metadata} -> metadata.directory end)
    |> Enum.sort_by(fn {directory, _files} -> directory end)
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

  # Component: Tasks/Files Sidebar
  defp tasks_files_sidebar(assigns) do
    ~H"""
    <aside class={[
      "h-screen bg-[var(--color-surface)] border-r border-[var(--color-border)] flex flex-col transition-all duration-300",
      @collapsed && "w-[60px]",
      !@collapsed && "w-80"
    ]}>
      <div class={[
        "flex items-center border-b border-[var(--color-border)] h-[70px] flex-shrink-0",
        @collapsed && "justify-center px-4",
        !@collapsed && "justify-between px-6"
      ]}>
        <%= if not @collapsed do %>
          <h3 class="text-lg font-semibold m-0">Tasks & Files</h3>
          <button
            phx-click="toggle_sidebar"
            class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded hover:bg-[var(--color-border-light)] transition-colors flex-shrink-0"
            type="button"
            title="Collapse"
          >
            <.icon name="hero-chevron-left" class="w-5 h-5" />
          </button>
        <% else %>
          <button
            phx-click="toggle_sidebar"
            class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded hover:bg-[var(--color-border-light)] transition-colors w-9 h-9 flex items-center justify-center"
            type="button"
            title="Expand"
          >
            <.icon name="hero-chevron-right" class="w-5 h-5" />
          </button>
        <% end %>
      </div>

      <%= if not @collapsed do %>
        <div class="flex-1 overflow-y-auto flex flex-col">
          <div class="flex bg-[var(--color-background)]">
            <button
              class={[
                "flex-1 py-3 px-4 bg-transparent text-[var(--color-text-secondary)] font-medium text-sm transition-all border-b-2 relative cursor-pointer border-t-0 border-l-0 border-r-0",
                @active_tab == "tasks" &&
                  "text-[var(--color-primary)] border-[var(--color-primary)] font-semibold bg-[var(--color-surface)]",
                @active_tab != "tasks" && "border-[var(--color-border)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border-light)]"
              ]}
              phx-click="switch_tab"
              phx-value-tab="tasks"
              type="button"
            >
              Tasks
            </button>
            <button
              class={[
                "flex-1 py-3 px-4 bg-transparent text-[var(--color-text-secondary)] font-medium text-sm transition-all border-b-2 relative cursor-pointer border-t-0 border-l-0 border-r-0",
                @active_tab == "files" &&
                  "text-[var(--color-primary)] border-[var(--color-primary)] font-semibold bg-[var(--color-surface)]",
                @active_tab != "files" && "border-[var(--color-border)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border-light)]"
              ]}
              phx-click="switch_tab"
              phx-value-tab="files"
              type="button"
            >
              Files
            </button>
          </div>

          <div class="flex-1 p-4 overflow-y-auto">
            <%= if @active_tab == "tasks" do %>
              <%= if @todos == [] do %>
                <div class="flex flex-col items-center justify-center h-full px-4 py-12 text-center">
                  <p class="text-[var(--color-text-secondary)] text-sm m-0">No tasks yet</p>
                </div>
              <% else %>
                <div class="flex flex-col gap-2">
                  <%= for todo <- @todos do %>
                    <div class="flex items-center gap-2 px-3 py-2 bg-[var(--color-background)] border border-[var(--color-border)] rounded-md">
                      <div class={[
                        "w-2 h-2 rounded-full flex-shrink-0",
                        todo.status == :pending && "bg-[var(--color-text-tertiary)]",
                        todo.status == :in_progress && "bg-[var(--color-warning)]",
                        todo.status == :completed && "bg-[var(--color-success)]"
                      ]}>
                      </div>
                      <span class="text-sm">{todo.content}</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% else %>
              <%= if @files == %{} do %>
                <div class="flex flex-col items-center justify-center h-full px-4 py-12 text-center">
                  <p class="text-[var(--color-text-secondary)] text-sm m-0">No files yet</p>
                </div>
              <% else %>
                <div class="flex flex-col gap-3">
                  <%!-- Group files by directory --%>
                  <%= for {directory, dir_files} <- group_files_by_directory(@files) do %>
                    <div class="flex flex-col gap-1">
                      <div class="flex items-center gap-2 px-2 py-1">
                        <.icon name="hero-folder" class="w-4 h-4 text-[var(--color-primary)] flex-shrink-0" />
                        <span class="text-xs font-semibold text-[var(--color-text-secondary)] tracking-wide">
                          {directory}
                        </span>
                      </div>
                      <div class="flex flex-col gap-1">
                        <%= for {path, _metadata} <- dir_files do %>
                          <div
                            class="flex items-center gap-2 pl-6 pr-3 py-2 bg-[var(--color-background)] border border-[var(--color-border)] rounded-md cursor-pointer hover:bg-[var(--color-border-light)] transition-colors"
                            phx-click="view_file"
                            phx-value-path={path}
                          >
                            <.icon
                              name="hero-document-text"
                              class="w-4 h-4 text-[var(--color-text-secondary)] flex-shrink-0"
                            />
                            <span class="text-sm truncate" title={path}>{Path.basename(path)}</span>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </aside>
    """
  end

  # Component: Chat Interface
  defp chat_interface(assigns) do
    ~H"""
    <div class="flex flex-col h-screen w-full bg-[var(--color-background)]">
      <header class="flex justify-between items-center px-6 h-[70px] border-b border-[var(--color-border)] bg-[var(--color-background)] flex-shrink-0">
        <div class="flex items-center gap-3">
          <.icon name="hero-chat-bubble-left-right" class="w-7 h-7 text-[var(--color-primary)]" />
          <h1 class="text-2xl font-semibold m-0">Agents Demo</h1>
        </div>

        <div class="flex items-center gap-2">
          <button
            phx-click="toggle_thread_history"
            class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:bg-[var(--color-border-light)] transition-colors"
            type="button"
            title="Thread History"
          >
            <.icon name="hero-clock" class="w-5 h-5" />
          </button>

          <button
            phx-click="new_thread"
            class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:bg-[var(--color-border-light)] transition-colors"
            type="button"
            title="New Thread"
          >
            <.icon name="hero-document-plus" class="w-5 h-5" />
          </button>
        </div>
      </header>

      <div class="flex flex-1 relative overflow-hidden">
        <%= if @is_thread_history_open do %>
          <div class="w-80 border-r border-[var(--color-border)] bg-[var(--color-surface)] overflow-y-auto flex-shrink-0 flex flex-col">
            <div class="flex justify-between items-center px-6 py-4 border-b border-[var(--color-border)]">
              <h3 class="m-0 text-lg">Thread History</h3>
              <button
                phx-click="toggle_thread_history"
                class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded"
                type="button"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>
            <div class="flex-1 p-4">
              <p class="text-[var(--color-text-secondary)] text-sm">No threads yet</p>
            </div>
          </div>
        <% end %>

        <div class="flex flex-1 flex-col overflow-hidden relative">
          <%= if not @has_messages do %>
            <div class="flex flex-col items-center justify-center h-full px-12 py-12 text-center">
              <.icon name="hero-chat-bubble-left-right" class="w-16 h-16 text-[var(--color-text-tertiary)] mb-6" />
              <h2 class="mb-2 text-[var(--color-text-primary)]">Start a Conversation</h2>
              <p class="text-[var(--color-text-secondary)] m-0">Ask me anything to get started</p>
            </div>
          <% end %>

          <%= if @has_messages do %>
            <div class="flex-1 overflow-y-auto px-6 py-6 flex flex-col gap-6" id="messages-list" phx-update="stream">
              <div :for={{id, message} <- @streams.messages} id={id}>
                <.message message={message} />
              </div>
            </div>
          <% end %>

          <%= if @loading do %>
            <div class="flex items-center gap-2 px-6 py-4 text-[var(--color-text-secondary)]">
              <div class="w-4 h-4 border-2 border-[var(--color-border)] border-t-[var(--color-primary)] rounded-full animate-spin">
              </div>
              <span>Thinking...</span>
            </div>
          <% end %>
        </div>
      </div>

      <form phx-submit="send_message" class="flex gap-3 px-6 py-4 border-t border-[var(--color-border)] bg-[var(--color-background)] flex-shrink-0">
        <input
          type="text"
          name="message"
          value={@input}
          phx-change="update_input"
          placeholder="Type your message..."
          class="flex-1 px-4 py-3 border border-[var(--color-border)] rounded-lg bg-[var(--color-surface)] text-[var(--color-text-primary)] text-base outline-none focus:border-[var(--color-primary)] transition-colors disabled:opacity-60 disabled:cursor-not-allowed"
          autocomplete="off"
          disabled={@loading}
        />
        <button
          type="submit"
          class="px-4 py-3 bg-[var(--color-primary)] text-white border-none rounded-lg hover:opacity-90 transition-opacity flex items-center justify-center disabled:opacity-50 disabled:cursor-not-allowed min-w-[48px]"
          disabled={@loading || @input == ""}
        >
          <.icon name="hero-paper-airplane" class="w-5 h-5" />
        </button>
      </form>
    </div>
    """
  end

  # Component: Individual Message
  defp message(assigns) do
    ~H"""
    <div class="flex gap-4 max-w-full">
      <div class={[
        "w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0",
        @message.type == :human && "bg-[var(--color-user-message)] text-white",
        @message.type == :ai && "bg-[var(--color-avatar-bg)] text-[var(--color-primary)]"
      ]}>
        <%= if @message.type == :human do %>
          <.icon name="hero-user" class="w-5 h-5" />
        <% else %>
          <.icon name="hero-cpu-chip" class="w-5 h-5" />
        <% end %>
      </div>

      <div class="flex-1 min-w-0">
        <div class={[
          "px-4 py-3 rounded-lg text-[var(--color-text-primary)] leading-relaxed",
          @message.type == :human &&
            "bg-[var(--color-user-message)] text-white",
          @message.type == :ai && "bg-[var(--color-surface)]"
        ]}>
          {@message.content}
        </div>
      </div>
    </div>
    """
  end

  # Component: File Viewer Modal
  defp file_viewer_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div
        class="bg-[var(--color-surface)] rounded-lg shadow-2xl max-w-4xl w-full max-h-[90vh] flex flex-col"
        phx-click-away="close_file_modal"
      >
        <%!-- Modal Header --%>
        <div class="flex items-center justify-between px-6 py-4 border-b border-[var(--color-border)]">
          <div class="flex items-center gap-3">
            <.icon name="hero-document-text" class="w-6 h-6 text-[var(--color-primary)]" />
            <h2 class="text-lg font-semibold text-[var(--color-text-primary)] m-0">
              {Path.basename(@path)}
            </h2>
          </div>
          <button
            phx-click="close_file_modal"
            class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded hover:bg-[var(--color-border-light)] transition-colors"
            type="button"
            title="Close"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <%!-- File Path --%>
        <div class="px-6 py-2 bg-[var(--color-background)] border-b border-[var(--color-border)]">
          <span class="text-xs text-[var(--color-text-secondary)] font-mono">{@path}</span>
        </div>
        <%!-- File Content --%>
        <div class="flex-1 overflow-hidden p-6">
          <textarea
            readonly
            class="w-full h-full px-4 py-3 border border-[var(--color-border)] rounded-lg bg-[var(--color-background)] text-[var(--color-text-primary)] text-sm font-mono resize-none focus:outline-none focus:border-[var(--color-primary)] transition-colors"
            style="min-height: 400px;"
          >{@content}</textarea>
        </div>
        <%!-- Modal Footer --%>
        <div class="flex items-center justify-end gap-3 px-6 py-4 border-t border-[var(--color-border)]">
          <button
            phx-click="close_file_modal"
            class="px-4 py-2 bg-[var(--color-primary)] text-white border-none rounded-lg hover:opacity-90 transition-opacity"
            type="button"
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end
end

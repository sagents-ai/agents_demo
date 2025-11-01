defmodule AgentsDemoWeb.ChatLive do
  use AgentsDemoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream(:messages, [])
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:thread_id, nil)
     |> assign(:todos, [])
     |> assign(:files, %{})
     |> assign(:sidebar_collapsed, false)
     |> assign(:sidebar_active_tab, "tasks")
     |> assign(:selected_sub_agent, nil)
     |> assign(:selected_file, nil)
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
      # Add user message immediately
      user_message = %{
        id: generate_id(),
        type: :human,
        content: message_text,
        timestamp: DateTime.utc_now()
      }

      socket =
        socket
        |> assign(:input, "")
        |> assign(:loading, true)
        |> assign(:has_messages, true)
        |> stream_insert(:messages, user_message)

      # TODO: Send to agent and handle response
      # For now, just simulate a response
      send(self(), {:agent_response, message_text})

      {:noreply, socket}
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
  def handle_info({:agent_response, _user_message}, socket) do
    # Simulate agent response
    ai_message = %{
      id: generate_id(),
      type: :ai,
      content: "This is a simulated response. Agent integration coming soon!",
      timestamp: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> assign(:loading, false)
     |> stream_insert(:messages, ai_message)}
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
          <div class="flex border-b border-[var(--color-border)] bg-[var(--color-background)]">
            <button
              class={[
                "flex-1 py-3 px-4 bg-transparent border-none text-[var(--color-text-secondary)] font-medium text-sm transition-all border-b-2 relative cursor-pointer",
                @active_tab == "tasks" &&
                  "text-[var(--color-primary)] border-[var(--color-primary)] font-semibold",
                @active_tab != "tasks" && "border-transparent hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border-light)]"
              ]}
              phx-click="switch_tab"
              phx-value-tab="tasks"
              type="button"
            >
              Tasks
            </button>
            <button
              class={[
                "flex-1 py-3 px-4 bg-transparent border-none text-[var(--color-text-secondary)] font-medium text-sm transition-all border-b-2 relative cursor-pointer",
                @active_tab == "files" &&
                  "text-[var(--color-primary)] border-[var(--color-primary)] font-semibold",
                @active_tab != "files" && "border-transparent hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border-light)]"
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
                <div class="flex flex-col gap-2">
                  <%= for {path, _content} <- @files do %>
                    <div class="flex items-center gap-2 px-3 py-2 bg-[var(--color-background)] border border-[var(--color-border)] rounded-md cursor-pointer hover:bg-[var(--color-border-light)] transition-colors">
                      <.icon name="hero-document-text" class="w-4 h-4 text-[var(--color-text-secondary)] flex-shrink-0" />
                      <span class="text-sm">{path}</span>
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
end

defmodule AgentsDemoWeb.ChatComponents do
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: AgentsDemoWeb.Endpoint,
    router: AgentsDemoWeb.Router,
    statics: AgentsDemoWeb.static_paths()

  import AgentsDemoWeb.CoreComponents

  alias Phoenix.LiveView.JS
  alias LangChain.MessageDelta
  alias LangChain.Message.ContentPart

  attr :collapsed, :boolean, default: false
  attr :active_tab, :string, default: "tasks"
  attr :todos, :list
  attr :files, :any

  # Component: Tasks/Files Sidebar
  def tasks_files_sidebar(assigns) do
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
                @active_tab != "tasks" &&
                  "border-[var(--color-border)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border-light)]"
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
                @active_tab != "files" &&
                  "border-[var(--color-border)] hover:text-[var(--color-text-primary)] hover:bg-[var(--color-border-light)]"
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
                <.todo_items todos={@todos} />
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
                        <.icon
                          name="hero-folder"
                          class="w-4 h-4 text-[var(--color-primary)] flex-shrink-0"
                        />
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

  defp group_files_by_directory(files) do
    files
    |> Enum.group_by(fn {_path, metadata} -> metadata.directory end)
    |> Enum.sort_by(fn {directory, _files} -> directory end)
  end

  attr :conversation_list, :list, required: true
  attr :conversation_id, :string, default: nil
  attr :has_more, :boolean, default: false
  attr :has_conversations, :boolean, default: false

  # Component: Conversation History Sidebar
  def conversation_history_sidebar(assigns) do
    ~H"""
    <div class="w-80 border-r border-[var(--color-border)] bg-[var(--color-surface)] flex-shrink-0 flex flex-col">
      <div class="flex justify-between items-center px-6 py-4 border-b border-[var(--color-border)]">
        <h3 class="m-0 text-lg">Thread History</h3>
        <button
          phx-click="toggle_thread_history"
          class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded hover:bg-[var(--color-border-light)] transition-colors"
          type="button"
          title="Close"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
      </div>

      <div
        id="conversation-list-container"
        class="flex-1 overflow-y-auto"
        phx-hook="ConversationList"
      >
        <%!-- Empty state shown when no conversations --%>
        <%= if not @has_conversations do %>
          <div class="flex flex-col items-center justify-center h-full px-4 py-12 text-center">
            <.icon name="hero-chat-bubble-left-right" class="w-12 h-12 text-[var(--color-text-tertiary)] mb-3" />
            <p class="text-[var(--color-text-secondary)] text-sm m-0">No conversations yet</p>
            <p class="text-[var(--color-text-tertiary)] text-xs m-0 mt-1">
              Start a new conversation to get started
            </p>
          </div>
        <% end %>

        <%!-- Stream container - ONLY contains stream items per LiveView docs --%>
        <div
          id="conversation-list"
          phx-update="stream"
          class="flex flex-col"
        >
          <div
            :for={{dom_id, conversation} <- @conversation_list}
            id={dom_id}
            class={[
              "px-4 py-3 border-b border-[var(--color-border)] cursor-pointer hover:bg-[var(--color-border-light)] transition-colors",
              conversation.id == @conversation_id && "bg-blue-50 dark:bg-blue-900/20 border-l-4 border-l-blue-500"
            ]}
            phx-click="load_conversation"
            phx-value-id={conversation.id}
          >
            <h4 class="text-sm font-medium text-[var(--color-text-primary)] m-0 mb-1 truncate">
              {conversation.title}
            </h4>
            <p class="text-xs text-[var(--color-text-secondary)] m-0">
              {format_relative_time(conversation.updated_at)}
            </p>
          </div>
        </div>

        <%= if @has_more do %>
          <div class="flex items-center justify-center py-4">
            <div class="w-4 h-4 border-2 border-[var(--color-border)] border-t-[var(--color-primary)] rounded-full animate-spin">
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper to format relative time
  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "Just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  attr :todos, :list, required: true, doc: "List of TODO items for display"

  def todo_items(assigns) do
    assigns = assign(assigns, :stats, calculate_todo_stats(assigns.todos))

    ~H"""
    <div>
      <%!-- Progress Summary --%>
      <div class="mb-4 pb-4 border-b border-[var(--color-border)]">
        <div class="flex items-center justify-between mb-2">
          <span class="text-sm font-semibold text-[var(--color-text-primary)]">
            {@stats.completed} of {@stats.total} completed
          </span>
          <span class="text-xs text-[var(--color-text-secondary)]">
            {@stats.progress_percentage}%
          </span>
        </div>
        <div class="w-full h-2 bg-[var(--color-border)] rounded-full overflow-hidden">
          <div
            class="h-full bg-[var(--color-success)] transition-all duration-300"
            style={"width: #{@stats.progress_percentage}%"}
          >
          </div>
        </div>
      </div>

      <%!-- Single ordered list of all TODOs --%>
      <div class="flex flex-col gap-2">
        <%= for todo <- @todos do %>
          <.todo_item todo={todo} />
        <% end %>
      </div>
    </div>
    """
  end

  defp calculate_todo_stats(todos) do
    total = length(todos)
    completed = Enum.count(todos, fn todo -> todo.status == :completed end)
    in_progress = Enum.count(todos, fn todo -> todo.status == :in_progress end)
    pending = Enum.count(todos, fn todo -> todo.status == :pending end)
    cancelled = Enum.count(todos, fn todo -> todo.status == :cancelled end)

    %{
      total: total,
      completed: completed,
      in_progress: in_progress,
      pending: pending,
      cancelled: cancelled,
      progress_percentage: if(total > 0, do: round(completed / total * 100), else: 0)
    }
  end

  attr :todo, :any, required: true

  def todo_item(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-3 py-2 bg-[var(--color-background)] border border-[var(--color-border)] rounded-md">
      <div class={[
        "w-2 h-2 rounded-full flex-shrink-0",
        @todo.status == :pending && "bg-[var(--color-text-tertiary)]",
        @todo.status == :in_progress && "bg-[var(--color-warning)]",
        @todo.status == :completed && "bg-[var(--color-success)]",
        @todo.status == :cancelled && "bg-[var(--color-error)]"
      ]}>
      </div>
      <span class={[
        "text-sm",
        @todo.status == :completed && "line-through text-[var(--color-text-secondary)]",
        @todo.status == :cancelled && "line-through text-[var(--color-text-tertiary)]"
      ]}>
        {@todo.content}
      </span>
    </div>
    """
  end

  attr :thread_id, :string
  attr :is_thread_history_open, :boolean, default: false
  attr :has_messages, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :streaming_delta, :any
  attr :streams, :any
  attr :input, :string, doc: "The user input being drafted for a new message"
  attr :agent_status, :atom, default: :idle
  attr :pending_tools, :list, default: []
  attr :current_scope, :any, default: nil
  attr :conversation_id, :string, default: nil
  attr :has_more_conversations, :boolean, default: false
  attr :has_conversations, :boolean, default: false

  # Component: Chat Interface
  def chat_interface(assigns) do
    ~H"""
    <div class="flex flex-col h-screen w-full bg-[var(--color-background)]">
      <header class="flex justify-between items-center px-6 h-[70px] border-b border-[var(--color-border)] bg-[var(--color-background)] flex-shrink-0">
        <div class="flex items-center gap-3">
          <.icon name="hero-chat-bubble-left-right" class="w-7 h-7 text-[var(--color-primary)]" />
          <h1 class="text-2xl font-semibold m-0">Agents Demo</h1>
        </div>

        <div class="flex items-center gap-4">
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

            <button
              phx-click="setup_demo_data"
              class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:bg-[var(--color-border-light)] transition-colors"
              type="button"
              title="Test TODOs"
            >
              <.icon name="hero-clipboard-document-check" class="w-5 h-5" />
            </button>
          </div>

          <%= if @current_scope do %>
            <div class="flex items-center gap-2 pl-4 border-l border-[var(--color-border)]">
              <span class="text-xs text-[var(--color-text-secondary)] px-2">
                {@current_scope.user.email}
              </span>
              <.link
                href={~p"/users/settings"}
                class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:bg-[var(--color-border-light)] transition-colors no-underline inline-flex items-center justify-center"
                title="Settings"
              >
                <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
              </.link>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:bg-[var(--color-border-light)] transition-colors no-underline inline-flex items-center justify-center"
                title="Log out"
              >
                <.icon name="hero-arrow-right-on-rectangle" class="w-5 h-5" />
              </.link>
            </div>
          <% end %>
        </div>
      </header>

      <div class="flex flex-1 relative overflow-hidden">
        <%= if @is_thread_history_open do %>
          <.conversation_history_sidebar
            conversation_list={@streams.conversation_list}
            conversation_id={@conversation_id}
            has_more={@has_more_conversations}
            has_conversations={@has_conversations}
          />
        <% end %>

        <div class="flex flex-1 flex-col overflow-hidden relative">
          <div
            id="chat-messages-container"
            class="flex-1 overflow-y-auto px-6 py-6 flex flex-col gap-6"
            phx-hook="ChatContainer"
          >
            <%= if not @has_messages do %>
              <div class="flex flex-col items-center justify-center h-full text-center">
                <.icon
                  name="hero-chat-bubble-left-right"
                  class="w-16 h-16 text-[var(--color-text-tertiary)] mb-6"
                />
                <h2 class="mb-2 text-[var(--color-text-primary)]">Start a Conversation</h2>
                <p class="text-[var(--color-text-secondary)] m-0">Ask me anything to get started</p>
              </div>
            <% end %>

            <%= if @has_messages do %>
              <div
                id="messages-list"
                phx-update="stream"
                class="flex flex-col gap-6"
              >
                <div :for={{id, message} <- @streams.messages} id={id}>
                  <.message message={message} />
                </div>
              </div>
            <% end %>

            <%= if @streaming_delta != nil do %>
              <div>
                <.streaming_message streaming_delta={@streaming_delta} />
              </div>
            <% end %>

            <%= if @loading && @streaming_delta == nil do %>
              <div class="flex items-center gap-2 text-[var(--color-text-secondary)]">
                <div class="w-4 h-4 border-2 border-[var(--color-border)] border-t-[var(--color-primary)] rounded-full animate-spin">
                </div>
                <span>Thinking...</span>
              </div>
            <% end %>
          </div>

          <%= if @agent_status == :interrupted && @pending_tools != [] do %>
            <.tool_approval_prompt pending_tools={@pending_tools} />
          <% end %>
        </div>
      </div>

      <form
        phx-submit="send_message"
        class="flex gap-3 px-6 py-5 border-t-2 border-[var(--color-border)] bg-[var(--color-background)] flex-shrink-0 shadow-[0_-4px_12px_rgba(0,0,0,0.05)]"
      >
        <input
          type="text"
          name="message"
          value={@input}
          phx-change="update_input"
          placeholder="Type your message..."
          class="flex-1 px-5 py-3.5 border-2 border-[var(--color-border)] rounded-xl bg-white dark:bg-[var(--color-surface)] text-[var(--color-text-primary)] text-base outline-none focus:border-[var(--color-user-message)] focus:ring-4 focus:ring-[var(--color-user-message)]/10 hover:border-[var(--color-text-tertiary)] transition-all shadow-sm disabled:opacity-60 disabled:cursor-not-allowed"
          autocomplete="off"
          disabled={@agent_status == :running}
        />
        <%= if @agent_status == :running do %>
          <button
            type="button"
            phx-click="cancel_agent"
            class="px-5 py-3.5 bg-red-600 text-white border-none rounded-xl hover:bg-red-700 hover:shadow-lg transition-all flex items-center justify-center min-w-[56px] shadow-md"
            title="Stop agent"
          >
            <.icon name="hero-stop" class="w-5 h-5" />
          </button>
        <% else %>
          <button
            type="submit"
            class="px-5 py-3.5 bg-[var(--color-user-message)] text-white border-none rounded-xl hover:opacity-90 hover:shadow-lg transition-all flex items-center justify-center disabled:opacity-50 disabled:cursor-not-allowed min-w-[56px] shadow-md"
            disabled={@input == ""}
          >
            <.icon name="hero-paper-airplane" class="w-5 h-5" />
          </button>
        <% end %>
      </form>
    </div>
    """
  end

  attr :message, :any, required: true

  # Component: Individual Message
  # Expects a DisplayMessage struct
  def message(assigns) do
    # Extract text content from DisplayMessage JSONB content field
    content_text = get_in(assigns.message.content, ["text"]) || ""
    is_thinking = assigns.message.content_type == "thinking"

    assigns =
      assigns
      |> assign(:content_text, content_text)
      |> assign(:is_thinking, is_thinking)

    ~H"""
    <%= if @is_thinking do %>
      <.thinking_message class="ml-14" message={@message} content_text={@content_text} />
    <% else %>
      <.text_message message={@message} content_text={@content_text} />
    <% end %>
    """
  end

  # Component: Text Message (normal message display)
  defp text_message(assigns) do
    ~H"""
    <div class="flex gap-4 max-w-full">
      <div class={[
        "w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0",
        @message.message_type == "user" && "bg-[var(--color-user-message)] text-white",
        @message.message_type == "assistant" && "bg-[var(--color-avatar-bg)] text-[var(--color-primary)]",
        @message.message_type == "tool" && "bg-[var(--color-border)] text-[var(--color-text-secondary)]"
      ]}>
        <%= if @message.message_type == "user" do %>
          <.icon name="hero-user" class="w-5 h-5" />
        <% else %>
          <.icon name="hero-cpu-chip" class="w-5 h-5" />
        <% end %>
      </div>

      <div class="flex-1 min-w-0 flex flex-col gap-3">
        <%= if @content_text && @content_text != "" do %>
          <div class={[
            "px-4 py-3 rounded-lg text-[var(--color-text-primary)] leading-relaxed",
            @message.message_type == "user" &&
              "bg-[var(--color-user-message)] text-white",
            @message.message_type == "assistant" && "bg-[var(--color-surface)]",
            @message.message_type == "tool" && "bg-[var(--color-background)]"
          ]}>
            <.markdown text={@content_text} invert={@message.message_type == "user"} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :message, :any, required: true
  attr :content_text, :string
  attr :class, :string, default: nil

  # Component: Thinking Message (subdued, collapsible display)
  defp thinking_message(assigns) do
    # Generate unique IDs for this thinking block
    thinking_id = "thinking-#{assigns.message.id}"
    chevron_id = "chevron-#{assigns.message.id}"

    assigns =
      assigns
      |> assign(:thinking_id, thinking_id)
      |> assign(:chevron_id, chevron_id)

    ~H"""
    <div class={["flex gap-2 max-w-full opacity-70 hover:opacity-100 transition-opacity", @class]}>
      <div class="flex-1 min-w-0">
        <button
          type="button"
          class="flex items-center gap-2 w-full text-left py-1 px-2 rounded hover:bg-[var(--color-border-light)] transition-colors cursor-pointer border-none bg-transparent"
          phx-click={
            JS.toggle(to: "##{@thinking_id}")
            |> JS.toggle_class("rotate-90", to: "##{@chevron_id}")
          }
        >
          <span class="text-sm italic text-[var(--color-text-secondary)]">Thinking</span>
          <.icon
            name="hero-chevron-right"
            id={@chevron_id}
            class="w-3 h-3 text-[var(--color-text-tertiary)] transition-transform duration-200"
          />
        </button>

        <%= if @content_text && @content_text != "" do %>
          <div id={@thinking_id} class="hidden mt-1 ml-5">
            <div class="px-3 py-2 rounded-lg bg-[var(--color-background)] border border-[var(--color-border)]">
              <.markdown
                text={@content_text}
                class="prose-sm text-xs text-[var(--color-text-secondary)]"
              />
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :tool_call, :any, required: true

  # Component: Tool Call Display
  def tool_call_item(assigns) do
    # Format arguments as JSON string for display
    assigns = assign(assigns, :args_json, format_tool_arguments(assigns.tool_call.arguments))

    ~H"""
    <div class="bg-[var(--color-background)] border border-[var(--color-border)] rounded-lg p-3">
      <div class="flex items-center gap-2 mb-2">
        <.icon name="hero-wrench-screwdriver" class="w-4 h-4 text-[var(--color-primary)]" />
        <span class="text-sm font-semibold text-[var(--color-text-primary)]">
          Tool Call: {@tool_call.name}
        </span>
      </div>
      <%= if @args_json && @args_json != "{}" do %>
        <div class="mt-2 pl-6">
          <details class="text-xs">
            <summary class="cursor-pointer text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)]">
              Arguments
            </summary>
            <pre class="mt-2 p-2 bg-[var(--color-surface)] rounded text-[var(--color-text-secondary)] overflow-x-auto"><code>{@args_json}</code></pre>
          </details>
        </div>
      <% end %>
    </div>
    """
  end

  attr :tool_result, :any, required: true

  # Component: Tool Result Display
  def tool_result_item(assigns) do
    assigns = assign(assigns, :is_error, is_tool_error(assigns.tool_result))

    ~H"""
    <div class={[
      "border rounded-lg p-3",
      @is_error && "bg-red-50 border-red-200",
      !@is_error && "bg-[var(--color-surface)] border-[var(--color-border)]"
    ]}>
      <div class="flex items-center gap-2 mb-2">
        <.icon
          name={if @is_error, do: "hero-exclamation-triangle", else: "hero-check-circle"}
          class={if @is_error, do: "w-4 h-4 text-red-600", else: "w-4 h-4 text-green-600"}
        />
        <span class="text-sm font-semibold text-[var(--color-text-primary)]">
          Tool Result: {@tool_result.name}
        </span>
      </div>
      <div class="pl-6 text-[var(--color-text-secondary)]">
        <details class="text-xs">
          <summary class="cursor-pointer hover:text-[var(--color-text-primary)] mb-1">
            Response
          </summary>
          <div class="mt-2 p-2 bg-[var(--color-background)] rounded">
            {format_tool_result_content(@tool_result.content)}
          </div>
        </details>
      </div>
    </div>
    """
  end

  # Helper function to format tool arguments as JSON
  defp format_tool_arguments(nil), do: "{}"

  defp format_tool_arguments(args) when is_map(args) do
    Jason.encode!(args, pretty: true)
  rescue
    _ -> inspect(args)
  end

  defp format_tool_arguments(args), do: inspect(args)

  # Helper function to format tool result content
  defp format_tool_result_content(content) when is_binary(content), do: content

  defp format_tool_result_content(content) when is_map(content) do
    Jason.encode!(content, pretty: true)
  rescue
    _ -> inspect(content)
  end

  defp format_tool_result_content(contents) when is_list(contents) do
    ContentPart.parts_to_string(contents)
  end

  defp format_tool_result_content(content), do: inspect(content)

  # Helper function to determine if a tool result is an error
  defp is_tool_error(%{is_error: true}), do: true
  defp is_tool_error(%{status: :error}), do: true
  defp is_tool_error(_), do: false

  attr :streaming_delta, :any, required: true

  # Component: Streaming Message (being typed)
  def streaming_message(assigns) do
    # Convert merged_content to string for display
    assigns =
      assign(
        assigns,
        :content,
        MessageDelta.content_to_string(assigns.streaming_delta, :text) || ""
      )

    ~H"""
    <div class="flex gap-4 max-w-full">
      <div class="w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0 bg-[var(--color-avatar-bg)] text-[var(--color-primary)]">
        <.icon name="hero-cpu-chip" class="w-5 h-5" />
      </div>

      <div class="flex-1 min-w-0">
        <div class="px-4 py-3 rounded-lg text-[var(--color-text-primary)] leading-relaxed bg-[var(--color-surface)]">
          <.markdown text={@content} />
          <span class="inline-block w-2 h-4 ml-1 bg-[var(--color-primary)] animate-pulse"></span>
        </div>
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :content, :string

  # Component: File Viewer Modal
  def file_viewer_modal(assigns) do
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

  attr :pending_tools, :list, required: true
  attr :test_mode, :boolean, default: false

  # Component: Tool Approval Prompt
  def tool_approval_prompt(assigns) do
    pending_count = Enum.count(assigns.pending_tools)

    # Only show the first tool, with a counter
    assigns =
      assigns
      |> assign(:current_tool, List.first(assigns.pending_tools))
      |> assign(:total_count, pending_count)
      |> assign(:remaining_count, pending_count - 1)

    ~H"""
    <div class="px-6 py-4 border-t-2 border-yellow-400 bg-yellow-50 dark:bg-yellow-900/20">
      <div class="max-w-3xl mx-auto">
        <div class="flex items-center justify-between gap-3 mb-3">
          <div class="flex items-center gap-3">
            <.icon
              name="hero-shield-exclamation"
              class="w-6 h-6 text-yellow-600 dark:text-yellow-400"
            />
            <h3 class="text-lg font-bold text-yellow-900 dark:text-yellow-100 m-0">
              Human Approval Required
            </h3>
          </div>
          <div class="flex items-center gap-2">
            <%= if @remaining_count > 0 do %>
              <span class="px-2 py-1 bg-yellow-200 dark:bg-yellow-800 text-yellow-900 dark:text-yellow-100 text-xs font-medium rounded">
                +{@remaining_count} more
              </span>
            <% end %>
            <%= if @test_mode do %>
              <span class="px-3 py-1 bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 text-xs font-bold rounded-full border border-blue-300 dark:border-blue-700">
                🧪 TEST MODE
              </span>
            <% end %>
          </div>
        </div>

        <p class="text-sm text-yellow-800 dark:text-yellow-200 mb-4">
          <%= if @test_mode do %>
            <strong>Test Mode:</strong>
            The agent wants to execute this tool. This is a mock request for UI testing - clicking approve/reject will only update the display.
          <% else %>
            The agent wants to execute this tool. Please review and approve or reject this action:
          <% end %>
        </p>

        <%!-- Show only the first tool (index 0) --%>
        <%= if @current_tool do %>
          <.tool_approval_item tool={@current_tool} index={0} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :tool, :map, required: true
  attr :index, :integer, required: true

  # Component: Individual Tool Approval Item
  def tool_approval_item(assigns) do
    assigns = assign(assigns, :args_json, format_tool_arguments(assigns.tool.arguments))

    ~H"""
    <div class="bg-white dark:bg-gray-800 border-2 border-yellow-300 dark:border-yellow-700 rounded-lg p-4 shadow-sm">
      <div class="flex flex-col gap-3">
        <div class="flex items-center gap-2">
          <.icon
            name="hero-wrench-screwdriver"
            class="w-5 h-5 text-yellow-600 dark:text-yellow-400 flex-shrink-0"
          />
          <span class="text-lg font-bold text-gray-900 dark:text-gray-100">
            {@tool.tool_name}
          </span>
        </div>

        <%= if @args_json && @args_json != "{}" do %>
          <details class="mt-1" open>
            <summary class="cursor-pointer text-sm font-medium text-gray-700 dark:text-gray-300 hover:text-gray-900 dark:hover:text-gray-100 mb-2">
              Arguments
            </summary>
            <pre class="mt-2 p-3 bg-gray-50 dark:bg-gray-900 rounded text-xs text-gray-800 dark:text-gray-200 overflow-x-auto border border-gray-200 dark:border-gray-700 font-mono"><code>{@args_json}</code></pre>
          </details>
        <% end %>

        <div class="flex items-center justify-end gap-3 pt-2 border-t border-gray-200 dark:border-gray-700">
          <button
            phx-click="reject_tool"
            phx-value-index={@index}
            class="px-5 py-2.5 bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-gray-100 border-none rounded-lg hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors font-medium"
            type="button"
          >
            <.icon name="hero-x-mark" class="w-4 h-4 inline-block mr-1" /> Reject
          </button>
          <button
            phx-click="approve_tool"
            phx-value-index={@index}
            class="px-5 py-2.5 bg-green-600 text-white border-none rounded-lg hover:bg-green-700 transition-colors font-medium shadow-sm"
            type="button"
          >
            <.icon name="hero-check" class="w-4 h-4 inline-block mr-1" /> Approve
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp mdex_config(md_content) do
    [
      streaming: true,
      markdown: md_content,
      extension: [
        strikethrough: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true,
        shortcodes: true
      ],
      parse: [
        smart: true,
        relaxed_tasklist_matching: true,
        relaxed_autolinks: true
      ],
      render: [
        unsafe_: true
      ]
      # syntax_highlight: [formatter: {:html_inline, theme: "github_light"}]
    ]
  end

  @doc """
  Render the raw content as markdown. Returns HTML rendered text.
  """
  def render_markdown(nil), do: Phoenix.HTML.raw(nil)

  def render_markdown(text) when is_binary(text) do
    # NOTE: This allows explicit HTML to come through.
    #   - Don't allow this with user input.
    text
    |> mdex_config()
    |> MDEx.new()
    |> MDEx.to_html!()
    |> Phoenix.HTML.raw()
  end

  @doc """
  Render a markdown containing web component.
  """
  attr :text, :string, required: true
  attr :class, :string, default: nil
  attr :invert, :boolean, default: false
  attr :rest, :global

  def markdown(%{text: nil} = assigns), do: ~H""

  def markdown(assigns) do
    ~H"""
    <div class="w-full">
      <div
        class={[
          "prose max-w-none prose-pre:whitespace-pre-wrap",
          @invert && "prose-invert text-white",
          !@invert && "dark:prose-invert",
          @class
        ]}
        {@rest}
      >
        {render_markdown(@text)}
      </div>
    </div>
    """
  end
end

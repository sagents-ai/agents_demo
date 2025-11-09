defmodule AgentsDemoWeb.ChatComponents do
  use Phoenix.Component
  import AgentsDemoWeb.CoreComponents

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

  # Component: Chat Interface
  def chat_interface(assigns) do
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

          <button
            phx-click="setup_demo_data"
            class="p-2 bg-transparent border-none text-[var(--color-text-secondary)] rounded-md hover:bg-[var(--color-border-light)] transition-colors"
            type="button"
            title="Test TODOs"
          >
            <.icon name="hero-clipboard-document-check" class="w-5 h-5" />
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
              class="flex-1 overflow-y-auto px-6 py-6 flex flex-col gap-6"
              id="messages-list"
              phx-update="stream"
            >
              <div :for={{id, message} <- @streams.messages} id={id}>
                <.message message={message} />
              </div>
            </div>
          <% end %>

          <%= if @streaming_delta != nil do %>
            <div class="px-6 py-4">
              <.streaming_message streaming_delta={@streaming_delta} />
            </div>
          <% end %>

          <%= if @loading && @streaming_delta == nil do %>
            <div class="flex items-center gap-2 px-6 py-4 text-[var(--color-text-secondary)]">
              <div class="w-4 h-4 border-2 border-[var(--color-border)] border-t-[var(--color-primary)] rounded-full animate-spin">
              </div>
              <span>Thinking...</span>
            </div>
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
          disabled={@loading}
        />
        <button
          type="submit"
          class="px-5 py-3.5 bg-[var(--color-user-message)] text-white border-none rounded-xl hover:opacity-90 hover:shadow-lg transition-all flex items-center justify-center disabled:opacity-50 disabled:cursor-not-allowed min-w-[56px] shadow-md"
          disabled={@loading || @input == ""}
        >
          <.icon name="hero-paper-airplane" class="w-5 h-5" />
        </button>
      </form>
    </div>
    """
  end

  attr :message, :any, required: true

  # Component: Individual Message
  def message(assigns) do
    ~H"""
    <div class="flex gap-4 max-w-full">
      <div class={[
        "w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0",
        @message.type == :user && "bg-[var(--color-user-message)] text-white",
        @message.type == :assistant && "bg-[var(--color-avatar-bg)] text-[var(--color-primary)]",
        @message.type == :tool && "bg-[var(--color-border)] text-[var(--color-text-secondary)]"
      ]}>
        <%= if @message.type == :user do %>
          <.icon name="hero-user" class="w-5 h-5" />
        <% else %>
          <.icon name="hero-cpu-chip" class="w-5 h-5" />
        <% end %>
      </div>

      <div class="flex-1 min-w-0 flex flex-col gap-3">
        <%= if @message.content && @message.content != "" do %>
          <div class={[
            "px-4 py-3 rounded-lg text-[var(--color-text-primary)] leading-relaxed",
            @message.type == :user &&
              "bg-[var(--color-user-message)] text-white",
            @message.type == :assistant && "bg-[var(--color-surface)]",
            @message.type == :tool && "bg-[var(--color-background)]"
          ]}>
            <.markdown text={@message.content} invert={@message.type == :user} />
          </div>
        <% end %>

        <%!-- Render tool calls if present --%>
        <%= if Map.get(@message, :tool_calls) && length(@message.tool_calls) > 0 do %>
          <div class="flex flex-col gap-2">
            <%= for tool_call <- @message.tool_calls do %>
              <.tool_call_item tool_call={tool_call} />
            <% end %>
          </div>
        <% end %>

        <%!-- Render tool results if present --%>
        <%= if Map.get(@message, :tool_results) && length(@message.tool_results) > 0 do %>
          <div class="flex flex-col gap-2">
            <%= for tool_result <- @message.tool_results do %>
              <.tool_result_item tool_result={tool_result} />
            <% end %>
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
      <div class="pl-6 text-sm text-[var(--color-text-secondary)]">
        <details open>
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
          {@content}
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

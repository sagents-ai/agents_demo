defmodule AgentsDemoWeb.AgentLiveHelpers do
  @moduledoc """
  Reusable helpers for agent event handling in LiveView.

  This module extracts common patterns from ChatLive to reduce boilerplate
  when integrating AI agents into Phoenix LiveView applications. All functions
  take a socket and return an updated socket, following the LiveView pattern.

  ## Usage

  In your LiveView handlers, delegate to these helpers:

      @impl true
      def handle_info({:agent, {:status_changed, :running, nil}}, socket) do
        {:noreply, AgentLiveHelpers.handle_status_running(socket)}
      end

  ## Customization

  This module was generated for your application and has hardcoded references to:
  - `AgentsDemo.Conversations` - Database context
  - `Sagents.AgentServer` - Agent server module

  You can customize message formatting, error handling, and logging by editing
  the generated functions directly.
  """

  import Phoenix.LiveView, only: [stream: 4, stream_insert: 3]
  import Phoenix.Component, only: [assign: 3]

  alias AgentsDemo.Conversations
  alias Sagents.AgentServer
  alias LangChain.MessageDelta

  require Logger

  # === STATUS CHANGE HANDLERS ===

  @doc """
  Handles agent status change to :running.

  Sets agent_status assign to :running to show loading state in UI.
  """
  def handle_status_running(socket) do
    assign(socket, :agent_status, :running)
  end

  @doc """
  Handles agent status change to :idle (execution completed successfully).

  Updates status, clears loading state and persists agent state.
  """
  def handle_status_idle(socket) do
    # Persist agent state after successful completion
    persist_agent_state(socket, "on_completion")

    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :idle)
  end

  @doc """
  Handles agent status change to :cancelled (user cancelled execution).

  Creates a cancellation message, updates status, clears loading and streaming state.

  Note: Does NOT persist agent state after cancellation because the state may be
  inconsistent or incomplete after the task was killed.
  """
  def handle_status_cancelled(socket) do
    cancellation_text = "_Agent execution cancelled by user. Partial response discarded._"

    cancellation_message =
      create_or_persist_message(
        socket,
        :assistant,
        cancellation_text
      )

    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :cancelled)
    |> assign(:streaming_delta, nil)
    |> stream_insert(:messages, cancellation_message)
  end

  @doc """
  Handles agent status change to :error (execution failed).

  Formats error message, creates assistant message with error, updates status,
  and persists agent state to preserve context up to the error.
  """
  def handle_status_error(socket, reason) do
    error_text = format_error_message(reason)

    error_message =
      create_or_persist_message(
        socket,
        :assistant,
        error_text
      )

    # Persist agent state to preserve context up to the error
    persist_agent_state(socket, "on_error")

    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :error)
    |> stream_insert(:messages, error_message)
  end

  @doc """
  Handles agent status change to :interrupted (waiting for human approval).

  Extracts action requests from interrupt data, updates status, and persists
  agent state to preserve the interrupt context.
  """
  def handle_status_interrupted(socket, interrupt_data) do
    action_requests = Map.get(interrupt_data, :action_requests, [])

    # Persist agent state to preserve context including the interrupt state
    persist_agent_state(socket, "on_interrupt")

    socket
    |> assign(:loading, false)
    |> assign(:agent_status, :interrupted)
    |> assign(:pending_tools, action_requests)
    |> assign(:interrupt_data, interrupt_data)
  end

  # === MESSAGING HANDLERS ===

  @doc """
  Handles streaming LLM deltas (incremental response chunks).

  Merges deltas into the accumulated streaming message and enriches with
  tool display information using early detection pattern.
  """
  def handle_llm_deltas(socket, deltas) do
    update_streaming_message(socket, deltas)
  end

  @doc """
  Handles complete LLM message received.

  Clears streaming delta unless there are pending tool calls, which need
  to stay visible until tools finish executing.
  """
  def handle_llm_message_complete(socket) do
    # Only clear streaming delta if no tool calls
    # If there are tool calls, keep delta visible until tools execute
    current_delta = socket.assigns.streaming_delta
    tool_calls = get_tool_display_info(current_delta)
    has_tools = tool_calls != []

    if has_tools do
      assign(socket, :loading, false)
    else
      socket
      |> assign(:streaming_delta, nil)
      |> assign(:loading, false)
    end
  end

  @doc """
  Handles batch of display messages saved to database.

  Reloads all messages from database for efficiency, unless there are pending
  tool calls in the streaming delta (which would cause duplicate display).
  """
  def handle_display_messages_batch_saved(socket, _display_messages) do
    # Check if there are pending tool calls - if so, don't reload yet
    current_delta = socket.assigns.streaming_delta
    tool_calls = get_tool_display_info(current_delta)
    has_pending_tools = tool_calls != []

    if has_pending_tools do
      # Don't reload messages yet - keep showing streaming delta
      assign(socket, :has_messages, true)
    else
      # No pending tools - reload messages and clear delta
      socket
      |> reload_messages_from_db()
      |> assign(:streaming_delta, nil)
      |> assign(:has_messages, true)
    end
  end

  @doc """
  Handles single display message saved to database.

  Reloads messages from database if conversation exists, otherwise inserts
  the message into the stream directly.
  """
  def handle_display_message_saved(socket, display_msg) do
    socket =
      if socket.assigns[:conversation_id] do
        reload_messages_from_db(socket)
      else
        stream_insert(socket, :messages, display_msg)
      end

    assign(socket, :has_messages, true)
  end

  # === TOOL EXECUTION HANDLERS ===

  @doc """
  Handles tool call identified event.

  Updates streaming delta with proper display_text from Function definition.
  Early detection may have added a placeholder, this updates with the correct name.
  """
  def handle_tool_call_identified(socket, tool_info) do
    current_delta = socket.assigns[:streaming_delta]
    display_name = tool_info[:display_text] || tool_info[:name]

    updated_delta = update_or_add_tool_info(current_delta, tool_info, display_name, :identified)

    assign(socket, :streaming_delta, updated_delta)
  end

  @doc """
  Handles tool execution started event.

  Updates database status to :executing and updates streaming delta status.
  """
  def handle_tool_execution_started(socket, tool_info) do
    display_name = tool_info[:display_text] || tool_info[:name]

    # Update database status
    socket =
      case Conversations.mark_tool_executing(tool_info.call_id) do
        {:ok, updated_msg} ->
          stream_insert(socket, :messages, updated_msg)

        _ ->
          socket
      end

    # Update streaming delta
    current_delta = socket.assigns[:streaming_delta]
    updated_delta = update_tool_status_in_delta(current_delta, tool_info, display_name, :executing)

    assign(socket, :streaming_delta, updated_delta)
  end

  @doc """
  Handles tool execution completed event.

  Updates database with result metadata, clears streaming delta, and reloads
  messages to show the completed status.
  """
  def handle_tool_execution_completed(socket, call_id, tool_result) do
    result_metadata = %{"result" => inspect(tool_result)}

    # Update database
    case Conversations.complete_tool_call(call_id, result_metadata) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.error("Failed to complete tool call: #{inspect(reason)}")
    end

    # Reload messages if we had a streaming delta
    socket =
      if socket.assigns.streaming_delta && socket.assigns[:conversation_id] do
        reload_messages_from_db(socket)
      else
        socket
      end

    assign(socket, :streaming_delta, nil)
  end

  @doc """
  Handles tool execution failed event.

  Updates database with error metadata, clears streaming delta, and reloads
  messages to show the failed status.
  """
  def handle_tool_execution_failed(socket, call_id, error) do
    # Update database
    case Conversations.fail_tool_call(call_id, %{"error" => inspect(error)}) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.error("Failed to mark tool call as failed: #{inspect(reason)}")
    end

    # Reload messages if we had a streaming delta
    socket =
      if socket.assigns.streaming_delta && socket.assigns[:conversation_id] do
        reload_messages_from_db(socket)
      else
        socket
      end

    assign(socket, :streaming_delta, nil)
  end

  # === LIFECYCLE HANDLERS ===

  @doc """
  Handles conversation title generated event.

  Updates conversation title in database and persists agent state with new title
  in metadata.

  Note: Page title formatting and conversation list updates are left to the
  calling LiveView as they are application-specific UI concerns.

  Returns the updated conversation in the socket assigns so the calling LiveView
  can update other UI elements as needed.
  """
  def handle_conversation_title_generated(socket, new_title, agent_id) do
    # Only process if it's for our agent
    if agent_id == socket.assigns[:agent_id] && socket.assigns[:conversation] do
      case Conversations.update_conversation(socket.assigns.conversation, %{title: new_title}) do
        {:ok, updated_conversation} ->
          # Persist agent state with new title in metadata
          state_data = AgentServer.export_state(socket.assigns.agent_id)
          Conversations.save_agent_state(socket.assigns.conversation_id, state_data)

          assign(socket, :conversation, updated_conversation)

        {:error, reason} ->
          Logger.error("Failed to update conversation title: #{inspect(reason)}")
          socket
      end
    else
      socket
    end
  end

  @doc """
  Handles agent shutdown event.

  Clears agent_id from assigns. The next interaction will restart the agent
  via Coordinator.
  """
  def handle_agent_shutdown(socket, shutdown_data) do
    Logger.info("Agent #{shutdown_data.agent_id} shutting down: #{shutdown_data.reason}")
    assign(socket, :agent_id, nil)
  end

  # === CORE HELPER FUNCTIONS ===

  @doc """
  Persists the current agent state to the database.

  Context label is used for logging/debugging to indicate when the state
  was persisted (e.g., "on_completion", "on_error", "on_interrupt").

  Returns the socket unchanged - state persistence is a side effect.
  """
  def persist_agent_state(socket, context_label) do
    if socket.assigns[:conversation_id] && socket.assigns[:agent_id] do
      try do
        state_data = AgentServer.export_state(socket.assigns.agent_id)

        case Conversations.save_agent_state(socket.assigns.conversation_id, state_data) do
          {:ok, _} ->
            Logger.info(
              "Persisted agent state for conversation #{socket.assigns.conversation_id} (#{context_label})"
            )

            socket

          {:error, reason} ->
            Logger.error("Failed to persist agent state (#{context_label}): #{inspect(reason)}")
            socket
        end
      rescue
        error ->
          Logger.error(
            "Exception while persisting agent state (#{context_label}): #{inspect(error)}"
          )

          socket
      end
    else
      Logger.debug("Skipping state persistence - no conversation_id or agent_id (#{context_label})")
      socket
    end
  end

  @doc """
  Accumulates streaming deltas and enriches with tool display information.

  Uses early detection pattern:
  1. Adds placeholder tool display info immediately when tool_calls appear
  2. Later refined by :tool_call_identified handler with proper display_text
  """
  def update_streaming_message(socket, deltas) do
    current_delta = socket.assigns.streaming_delta
    updated_delta = MessageDelta.merge_deltas(current_delta, deltas)

    # EARLY DETECTION: Add placeholder display info for new tool calls
    updated_delta =
      if updated_delta && updated_delta.tool_calls && updated_delta.tool_calls != [] do
        existing_tools = MessageDelta.get_tool_display_info(updated_delta)

        existing_indices =
          MapSet.new(Enum.with_index(existing_tools) |> Enum.map(fn {_, idx} -> idx end))

        # Find new tool calls that need enrichment
        new_tool_calls =
          updated_delta.tool_calls
          |> Enum.with_index()
          |> Enum.filter(fn {tc, idx} ->
            tc.name != nil && !MapSet.member?(existing_indices, idx)
          end)

        Enum.reduce(new_tool_calls, updated_delta, fn {tc, _idx}, delta_acc ->
          display_name = tc.name |> String.replace("_", " ") |> String.capitalize()

          tool_info = %{
            name: tc.name,
            call_id: tc.call_id,
            display_name: display_name,
            status: :identified
          }

          MessageDelta.add_tool_display_info(delta_acc, tool_info)
        end)
      else
        updated_delta
      end

    assign(socket, :streaming_delta, updated_delta)
  end

  @doc """
  Reloads display messages from the database and updates the stream.

  Uses reset: true to ensure proper ordering and clean state.
  """
  def reload_messages_from_db(socket) do
    if socket.assigns[:conversation_id] do
      messages = Conversations.load_display_messages(socket.assigns.conversation_id)
      stream(socket, :messages, messages, reset: true)
    else
      socket
    end
  end

  @doc """
  Creates a message in database if conversation exists, otherwise creates in-memory fallback.

  This ensures the UI always shows a message even if database persistence fails.

  Returns the message map (not the socket).
  """
  def create_or_persist_message(socket, message_type, text) do
    if socket.assigns[:conversation_id] do
      case Conversations.append_text_message(
             socket.assigns.conversation_id,
             message_type,
             text
           ) do
        {:ok, display_msg} ->
          display_msg

        {:error, reason} ->
          Logger.error("Failed to persist #{message_type} message: #{inspect(reason)}")
          create_fallback_message(message_type, text)
      end
    else
      create_fallback_message(message_type, text)
    end
  end

  # === PRIVATE HELPERS ===

  defp create_fallback_message(message_type, text) do
    %{
      id: generate_id(),
      message_type: message_type,
      content_type: "text",
      content: %{"text" => text},
      timestamp: DateTime.utc_now()
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp format_error_message(reason) do
    error_display =
      case reason do
        %LangChain.LangChainError{} = error -> error.message
        other -> inspect(other)
      end

    "Sorry, I encountered an error: #{error_display}"
  end

  defp get_tool_display_info(nil), do: []

  defp get_tool_display_info(delta) do
    LangChain.MessageDelta.get_tool_display_info(delta)
  end

  defp update_or_add_tool_info(current_delta, tool_info, display_name, status) do
    if current_delta do
      tool_calls = get_tool_display_info(current_delta)

      updated_tool_calls =
        Enum.map(tool_calls, fn tool ->
          if tool.name == tool_info.name do
            %{tool | display_name: display_name}
          else
            tool
          end
        end)

      updated_tool_calls =
        if Enum.any?(updated_tool_calls, fn t -> t.name == tool_info.name end) do
          updated_tool_calls
        else
          display_info = %{
            call_id: tool_info.call_id,
            name: tool_info.name,
            display_name: display_name,
            arguments: tool_info.arguments || %{},
            status: status
          }

          updated_tool_calls ++ [display_info]
        end

      updated_metadata = Map.put(current_delta.metadata || %{}, :streaming_tool_calls, updated_tool_calls)
      %{current_delta | metadata: updated_metadata}
    else
      display_info = %{
        call_id: tool_info.call_id,
        name: tool_info.name,
        display_name: display_name,
        arguments: tool_info.arguments || %{},
        status: status
      }

      LangChain.MessageDelta.add_tool_display_info(current_delta, display_info)
    end
  end

  defp update_tool_status_in_delta(current_delta, tool_info, display_name, status) do
    if current_delta do
      tool_calls = get_tool_display_info(current_delta)

      updated_tool_calls =
        Enum.map(tool_calls, fn tool ->
          if tool.call_id == tool_info.call_id or tool.name == tool_info.name do
            %{tool | status: status}
          else
            tool
          end
        end)

      updated_metadata = Map.put(current_delta.metadata || %{}, :streaming_tool_calls, updated_tool_calls)
      %{current_delta | metadata: updated_metadata}
    else
      display_info = %{
        call_id: tool_info.call_id,
        name: tool_info.name,
        display_name: display_name,
        arguments: tool_info.arguments || %{},
        status: status
      }

      LangChain.MessageDelta.add_tool_display_info(current_delta, display_info)
    end
  end

end

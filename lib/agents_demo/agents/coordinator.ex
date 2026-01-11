defmodule AgentsDemo.Agents.Coordinator do
  @moduledoc """
  Coordinates the lifecycle of conversation-centric agents.

  This module provides a unified entry point for:
  - Creating agents with proper agent_id management
  - Starting agent sessions tied to conversations
  - Loading/restoring conversation state
  - Managing agent_id → conversation_id mapping

  ## Design Philosophy

  Each conversation gets its own agent process with:
  - agent_id = "conversation-{conversation_id}"
  - Agent configuration from code (via Factory)
  - State from database (if restoring)

  ## Usage

      # Start a session for a conversation
      {:ok, session} = Coordinator.start_conversation_session(conversation_id)

      # Send messages (agent_id managed internally)
      AgentServer.add_message(session.agent_id, message)

      # Stop session when done
      Coordinator.stop_conversation_session(conversation_id)
  """

  alias __MODULE__
  alias LangChain.Agents.{State, AgentServer, AgentSupervisor}
  alias LangChain.Message
  alias LangChain.Message.DisplayHelpers
  alias AgentsDemo.{Conversations, Agents.Factory}

  require Logger

  # PubSub configuration - single source of truth
  @pubsub_module Phoenix.PubSub
  @pubsub_name AgentsDemo.PubSub

  # Presence module for tracking conversation viewers
  @presence_module AgentsDemoWeb.Presence

  # Default inactivity timeout
  @inactivity_timeout_minutes 10

  @doc """
  Start an agent session for a conversation.

  Creates the agent, loads/creates state, and starts the AgentServer.
  This is the recommended entry point for conversation-based agent sessions.

  This function is idempotent - calling it multiple times for the same
  conversation returns the same session without error.

  ## Options

  - `:interrupt_on` - Map of tool names to interrupt configuration
  - `:user` - Current user struct (for audit/permissions)
  - `:filesystem_scope` - Scope tuple for filesystem reference (e.g., {:user, 123}) (optional)
  - `:inactivity_timeout` - Timeout in milliseconds for automatic shutdown (optional, default: 1 hour)

  ## Returns

  - `{:ok, session}` - Session info with agent_id and server_pid
  - `{:error, reason}` - Failed to start

  ## Examples

      # Start new conversation agent (in-memory only)
      {:ok, session} = Coordinator.start_conversation_session(123)
      # => %{agent_id: "conversation-123", pid: #PID<...>, conversation_id: 123}

      # With filesystem scope (references independently-running filesystem)
      {:ok, scope} = DemoSetup.ensure_user_filesystem(user_id)
      {:ok, session} = Coordinator.start_conversation_session(123, filesystem_scope: scope)

      # Already running? Returns same session
      {:ok, session} = Coordinator.start_conversation_session(123)
      # => %{agent_id: "conversation-123", pid: #PID<...>, conversation_id: 123}
  """
  def start_conversation_session(conversation_id, opts \\ []) do
    agent_id = conversation_agent_id(conversation_id)

    case AgentServer.get_pid(agent_id) do
      nil ->
        do_start_session(conversation_id, agent_id, opts)

      pid ->
        {:ok,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}
    end
  end

  @doc """
  Stop an agent session for a conversation.

  Stops the AgentServer (which also stops the AgentSupervisor tree).
  State should be persisted before calling this if needed.
  """
  def stop_conversation_session(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    # Stopping AgentServer will stop the entire AgentSupervisor tree
    AgentServer.stop(agent_id)
    :ok
  end

  @doc """
  Get the agent_id for a conversation.

  This encapsulates the mapping strategy (conversation-centric model).
  Returns the conversation_id as-is (a string UUID).
  """
  def conversation_agent_id(conversation_id) do
    conversation_id
  end

  @doc """
  Check if an agent session is running for a conversation.
  """
  def session_running?(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    AgentServer.get_pid(agent_id) != nil
  end

  @doc """
  Create an agent for a conversation without starting it.

  Useful for testing or when you need the agent struct separately.
  """
  def create_conversation_agent(conversation_id, opts \\ []) do
    agent_id = conversation_agent_id(conversation_id)
    Factory.create_demo_agent(Keyword.put(opts, :agent_id, agent_id))
  end

  @doc """
  Create a state for a conversation, loading from DB if exists.

  Note: The library automatically injects agent_id, so we don't need to set it
  when creating fresh states. For deserialization, we still need to provide it
  since agent_id is not persisted.
  """
  def create_conversation_state(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)

    case Conversations.load_agent_state(conversation_id) do
      {:ok, exported_state} ->
        Logger.info("Found saved state for conversation #{conversation_id}, attempting to restore...")

        # exported_state has structure: %{"version" => 1, "state" => %{"messages" => [...], ...}}
        # We need to pass just the nested "state" field to the deserializer
        nested_state = exported_state["state"]

        if is_nil(nested_state) do
          Logger.warning(
            "Exported state for conversation #{conversation_id} has no 'state' field, using fresh state"
          )

          {:ok, State.new!(%{})}
        else
          # Deserialize with proper agent_id (agent_id is not serialized)
          case State.from_serialized(agent_id, nested_state) do
            {:ok, state} ->
              Logger.info(
                "Successfully restored agent state for conversation #{conversation_id} with #{length(state.messages)} messages"
              )

              {:ok, state}

            {:error, reason} ->
              Logger.warning(
                "Failed to deserialize agent state for conversation #{conversation_id}: #{inspect(reason)}, using fresh state"
              )

              {:ok, State.new!(%{})}
          end
        end

      {:error, :not_found} ->
        Logger.info("No saved state found for conversation #{conversation_id}, creating fresh state")
        # Create fresh state - library will inject agent_id automatically
        {:ok, State.new!(%{})}
    end
  end

  @doc """
  Ensure the current process is subscribed to agent events for a conversation.

  This function is idempotent - safe to call multiple times. It delegates to
  LangChain.PubSub.subscribe/3 for subscription management.

  This works even when the agent isn't running because PubSub topics exist
  independently of processes. When the agent later starts and publishes events,
  subscribers will receive them.

  Returns `:ok` on success.

  ## Examples

      # In a LiveView - safe to call multiple times
      Coordinator.ensure_subscribed_to_conversation(conversation_id)

      # Even if user clicks same conversation repeatedly, only subscribes once
      Coordinator.ensure_subscribed_to_conversation(conversation_id)
      Coordinator.ensure_subscribed_to_conversation(conversation_id)  # No-op

      # Same process can subscribe to multiple conversations
      Coordinator.ensure_subscribed_to_conversation(conversation_id_1)
      Coordinator.ensure_subscribed_to_conversation(conversation_id_2)
  """
  def ensure_subscribed_to_conversation(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    topic = agent_topic(agent_id)
    LangChain.PubSub.subscribe(@pubsub_module, @pubsub_name, topic)
  end

  @doc """
  Subscribe to agent events for a conversation without requiring the agent to be running.

  Note: Consider using `ensure_subscribed_to_conversation/1` instead, which prevents
  duplicate subscriptions if called multiple times. This function uses raw_subscribe
  which does not prevent duplicates.

  This works because PubSub topics exist independently of processes. When the agent
  later starts and publishes events, subscribers will receive them.

  Returns `:ok` on success.
  """
  def subscribe_to_conversation(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    topic = agent_topic(agent_id)
    LangChain.PubSub.raw_subscribe(@pubsub_module, @pubsub_name, topic)
  end

  @doc """
  Unsubscribe from agent events for a conversation.

  Clears the subscription tracking in the Process dictionary.
  """
  def unsubscribe_from_conversation(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    topic = agent_topic(agent_id)
    LangChain.PubSub.unsubscribe(@pubsub_module, @pubsub_name, topic)
  end

  @doc """
  Track a viewer's presence in a conversation.

  Call this in your LiveView mount after the socket is connected to enable smart
  agent shutdown - when no viewers are present and the agent becomes idle, it can
  shutdown immediately to free resources.

  Phoenix.Presence automatically removes the entry when the tracked process terminates,
  so manual cleanup is not needed.

  ## Parameters

    - `conversation_id` - The conversation being viewed
    - `viewer_id` - Unique identifier for the viewer (typically user_id)
    - `pid` - The process to track (typically self())
    - `metadata` - Optional metadata map (default: empty map)

  ## Returns

    - `{:ok, ref}` - Presence tracked successfully
    - `{:error, reason}` - Failed to track presence

  ## Examples

      # In a LiveView after socket is connected
      if connected?(socket) do
        {:ok, _ref} = Coordinator.track_conversation_viewer(conversation_id, user.id, self())
      end

      # With metadata
      Coordinator.track_conversation_viewer(
        conversation_id,
        user.id,
        self(),
        %{username: user.name}
      )
  """
  def track_conversation_viewer(conversation_id, viewer_id, pid, metadata \\ %{}) do
    topic = presence_topic(conversation_id)
    full_metadata = Map.merge(%{joined_at: System.system_time(:second)}, metadata)
    LangChain.Presence.track(@presence_module, topic, viewer_id, pid, full_metadata)
  end

  @doc """
  Untrack a viewer's presence from a conversation.

  Call this when switching between conversations to properly clean up presence tracking.

  ## Parameters

    - `conversation_id` - The conversation to untrack from
    - `viewer_id` - Unique identifier for the viewer (typically user_id)
    - `pid` - The process to untrack (typically self())

  ## Returns

    - `:ok` - Presence untracked successfully

  ## Examples

      # When switching conversations
      Coordinator.untrack_conversation_viewer(old_conversation_id, user.id, self())
  """
  def untrack_conversation_viewer(conversation_id, viewer_id, pid) do
    topic = presence_topic(conversation_id)
    LangChain.Presence.untrack(@presence_module, topic, viewer_id, pid)
  end

  @doc """
  List all viewers currently present in a conversation.

  Returns a map of viewer_id => metadata for all tracked viewers.
  """
  def list_conversation_viewers(conversation_id) do
    topic = presence_topic(conversation_id)
    LangChain.Presence.list(@presence_module, topic)
  end

  @doc """
  Get the PubSub topic for a conversation's agent.

  Useful for direct PubSub operations if needed.
  """
  def conversation_topic(conversation_id) do
    agent_id = conversation_agent_id(conversation_id)
    agent_topic(agent_id)
  end

  @doc """
  Get the PubSub name used by this coordinator.

  Returns the atom name of the PubSub server (e.g., AgentsDemo.PubSub).
  """
  def pubsub_name do
    @pubsub_name
  end

  @doc """
  Save a LangChain Message as DisplayMessage(s) to the database.

  Converts a single LangChain.Message into one or more DisplayMessage records
  and persists them to the conversation. A single Message can produce multiple
  DisplayMessages (e.g., text + tool_calls, or multiple tool_results).

  This function bridges the gap between the library's Message-centric world
  and the application's DisplayMessage persistence layer.

  ## Parameters

  - `conversation_id` - The conversation ID
  - `message` - A `%LangChain.Message{}` struct

  ## Returns

  - `{:ok, [%DisplayMessage{}]}` - List of saved DisplayMessages
  - `{:error, reason}` - Failed to save

  ## Examples

      # User message
      message = Message.new_user!("Hello")
      {:ok, [display_msg]} = Coordinator.save_message(conversation_id, message)

      # Assistant message with text and tool calls
      message = Message.new_assistant!(%{
        content: "Let me search...",
        tool_calls: [ToolCall.new!(%{...})]
      })
      {:ok, [text_msg, tool_call_msg]} = Coordinator.save_message(conversation_id, message)
  """
  def save_message(conversation_id, %Message{} = message) do
    Logger.debug("Coordinator.save_message called for conversation #{conversation_id}, message role: #{message.role}")

    # Use library helper to extract displayable items
    display_items = DisplayHelpers.extract_display_items(message)
    Logger.debug("Extracted #{length(display_items)} display items from message")

    # Warn if no content (shouldn't happen, but good to track)
    if Enum.empty?(display_items) do
      Logger.warning("Received Message with no displayable content: #{inspect(message)}")
      {:ok, []}  # Return empty list, nothing to save or display
    else
      # Convert and persist each item, stopping on first error
      result =
        Enum.reduce_while(display_items, {:ok, []}, fn item, {:ok, acc} ->
          # Convert atom keys to string keys for Conversations.append_display_message/2
          attrs = %{
            "message_type" => Atom.to_string(item.message_type),
            "content_type" => Atom.to_string(item.type),
            "content" => item.content
          }

          Logger.debug("Attempting to save display message: type=#{attrs["content_type"]}, message_type=#{attrs["message_type"]}")

          case Conversations.append_display_message(conversation_id, attrs) do
            {:ok, display_msg} ->
              Logger.debug("Successfully persisted DisplayMessage id=#{display_msg.id}")
              {:cont, {:ok, acc ++ [display_msg]}}

            {:error, reason} ->
              Logger.error(
                "Failed to persist DisplayMessage (#{attrs["content_type"]}): #{inspect(reason)}"
              )
              {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, display_messages} ->
          Logger.debug("Returning #{length(display_messages)} display messages")
          {:ok, display_messages}

        error ->
          error
      end
    end
  end

  ## Private Functions

  # Private helper for agent PubSub topic naming
  defp agent_topic(agent_id) do
    "agent_server:#{agent_id}"
  end

  # Private helper for presence topic naming
  defp presence_topic(conversation_id) do
    "conversation:#{conversation_id}"
  end

  defp do_start_session(conversation_id, agent_id, opts) do
    Logger.info("Starting agent session for conversation #{conversation_id}")

    # 1. Extract filesystem_scope from options
    filesystem_scope = Keyword.get(opts, :filesystem_scope)

    # 2. Create agent from factory (configuration from code) with filesystem_scope
    factory_opts =
      opts
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:filesystem_scope, filesystem_scope)

    {:ok, agent} = Factory.create_demo_agent(factory_opts)

    # 3. Load or create state (data from database)
    {:ok, state} = create_conversation_state(conversation_id)

    # 4. Extract configuration from options
    # Default to 10 minutes of inactivity before automatic shutdown
    inactivity_timeout = Keyword.get(opts, :inactivity_timeout, :timer.minutes(@inactivity_timeout_minutes))

    # 5. Start the AgentSupervisor with proper configuration
    # Use start_link_sync to ensure AgentServer is ready before returning
    # This prevents race conditions where subscribers try to connect before the agent is ready
    # CRITICAL: Must provide unique name for each supervisor based on agent_id
    # Without this, all supervisors try to register with the same default name causing collisions
    supervisor_name = AgentSupervisor.get_name(agent_id)

    # Configure presence tracking for smart shutdown
    presence_tracking = [
      enabled: true,
      presence_module: @presence_module,
      topic: presence_topic(conversation_id)
    ]

    supervisor_config = [
      name: supervisor_name,
      agent: agent,
      initial_state: state,
      pubsub: {@pubsub_module, @pubsub_name},
      # Enable debug event broadcasting
      debug_pubsub: {@pubsub_module, @pubsub_name},
      inactivity_timeout: inactivity_timeout,
      presence_tracking: presence_tracking,
      # Enable presence-based agent discovery for debugger
      presence_module: @presence_module,
      conversation_id: conversation_id,
      save_new_message_fn: &Coordinator.save_message/2
    ]

    case AgentSupervisor.start_link_sync(supervisor_config) do
      {:ok, _supervisor_pid} ->
        # AgentServer is guaranteed to be ready now
        pid = AgentServer.get_pid(agent_id)

        {:ok,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}

      {:error, {:already_started, _supervisor_pid}} ->
        # Race condition - someone else started it
        # Return :ok tuple for consistent API (idempotent)
        pid = AgentServer.get_pid(agent_id)

        {:ok,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}

      {:error, reason} ->
        Logger.error("Failed to start agent session: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

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

  alias LangChain.Agents.{State, AgentServer, AgentSupervisor}
  alias AgentsDemo.{Conversations, Agents.Factory}

  require Logger

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
  """
  def conversation_agent_id(conversation_id) do
    "conversation-#{conversation_id}"
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
      {:ok, state_data} ->
        # Deserialize with proper agent_id (agent_id is not serialized)
        case State.from_serialized(agent_id, state_data) do
          {:ok, state} ->
            {:ok, state}

          {:error, reason} ->
            Logger.warning(
              "Failed to deserialize agent state for conversation #{conversation_id}: #{inspect(reason)}, using fresh state"
            )

            {:ok, State.new!(%{})}
        end

      {:error, :not_found} ->
        # Create fresh state - library will inject agent_id automatically
        {:ok, State.new!(%{})}
    end
  end

  ## Private Functions

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

    supervisor_config = [
      name: supervisor_name,
      agent: agent,
      initial_state: state,
      pubsub: {Phoenix.PubSub, AgentsDemo.PubSub},
      inactivity_timeout: inactivity_timeout
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

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

  @doc """
  Start an agent session for a conversation.

  Creates the agent, loads/creates state, and starts the AgentServer.
  This is the recommended entry point for conversation-based agent sessions.

  ## Options

  - `:interrupt_on` - Map of tool names to interrupt configuration
  - `:user` - Current user struct (for audit/permissions)

  ## Returns

  - `{:ok, session}` - Session info with agent_id and server_pid
  - `{:already_started, session}` - Agent already running (idempotent)
  - `{:error, reason}` - Failed to start

  ## Examples

      # Start new conversation agent
      {:ok, session} = Coordinator.start_conversation_session(123)
      # => %{agent_id: "conversation-123", pid: #PID<...>, conversation_id: 123}

      # Already running? No-op
      {:already_started, session} = Coordinator.start_conversation_session(123)
  """
  def start_conversation_session(conversation_id, opts \\ []) do
    agent_id = conversation_agent_id(conversation_id)

    case AgentServer.get_pid(agent_id) do
      nil ->
        do_start_session(conversation_id, agent_id, opts)

      pid ->
        {:already_started,
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
        State.from_serialized(agent_id, state_data["state"])

      {:error, :not_found} ->
        # Create fresh state - library will inject agent_id automatically
        {:ok, State.new!(%{})}
    end
  end

  ## Private Functions

  defp do_start_session(conversation_id, agent_id, opts) do
    # 1. Create agent from factory (configuration from code)
    {:ok, agent} = Factory.create_demo_agent(Keyword.put(opts, :agent_id, agent_id))

    # 2. Load or create state (data from database)
    {:ok, state} = create_conversation_state(conversation_id)

    # 3. Start the AgentSupervisor with proper configuration
    supervisor_config = [
      agent: agent,
      initial_state: state,
      pubsub: {Phoenix.PubSub, AgentsDemo.PubSub},
      # Conversations can timeout after inactivity
      inactivity_timeout: :timer.hours(1)
    ]

    case AgentSupervisor.start_link(supervisor_config) do
      {:ok, _supervisor_pid} ->
        # Get the AgentServer pid for convenience
        pid = AgentServer.get_pid(agent_id)

        {:ok,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}

      {:error, {:already_started, _supervisor_pid}} ->
        # Race condition - someone else started it
        pid = AgentServer.get_pid(agent_id)

        {:already_started,
         %{
           agent_id: agent_id,
           pid: pid,
           conversation_id: conversation_id
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

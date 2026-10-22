defmodule AgentsDemo.Agents.ModeAnnouncer do
  @moduledoc """
  Tells the user when the agent changes mode, with an assistant message in the
  conversation's transcript.

  The model reads the `switch_mode` tool result; the user reads this. It is the
  `:on_switch` callback of the factory's `Sagents.Middleware.AbilitySetSwitcher`,
  given as a `{module, function, args}` tuple so it stays callable when Horde
  moves an agent to a node running a different build.
  """

  alias Sagents.AgentServer

  @announcements %{
    "pirate" => "Hoisting the colors. Speaking as a pirate from here on.",
    "kung_foo" => "Switching to focus on workplace counsel, in the voice of a Kung Fu master."
  }

  @doc """
  Saves the announcement for the mode switched to as a synthetic assistant
  display message. A switch to no mode, or to a mode without an announcement,
  adds nothing.
  """
  @spec announce(map()) :: :ok
  def announce(%{agent_id: agent_id, to: to}) do
    case Map.fetch(@announcements, to) do
      {:ok, text} ->
        AgentServer.save_synthetic_message_from(agent_id, %{
          message_type: "assistant",
          content_type: "text",
          content: %{"text" => text}
        })

      :error ->
        :ok
    end
  end
end

defmodule AgentsDemoWeb.Presence do
  @moduledoc """
  Phoenix Presence for tracking users viewing conversations.

  This enables smart agent shutdown: when no users are viewing a conversation
  and the agent becomes idle, it can shutdown immediately to free resources.
  """
  use Phoenix.Presence,
    otp_app: :agents_demo,
    pubsub_server: AgentsDemo.PubSub
end

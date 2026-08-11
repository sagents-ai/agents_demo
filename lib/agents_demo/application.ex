defmodule AgentsDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      AgentsDemoWeb.Telemetry,
      AgentsDemo.Repo,
      {DNSCluster, query: Application.get_env(:agents_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AgentsDemo.PubSub},
      AgentsDemoWeb.Presence,
      # Sagents infrastructure (registry + dynamic supervisors).
      #
      # After Repo/PubSub so agents shut down before them (reverse order),
      # allowing terminate/2 to persist state and broadcast shutdown events.
      #
      # Before the Endpoint for the same reason read the other direction: OTP
      # stops children in reverse, so the Endpoint stops accepting requests
      # first and the registry is still alive to serve whatever is in flight.
      # Listed after the Endpoint instead, every request for the rest of the
      # drain would land on a dead registry.
      Sagents.Supervisor,
      # Start to serve requests, typically the last entry
      AgentsDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentsDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentsDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

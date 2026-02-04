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

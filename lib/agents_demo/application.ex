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
      # Serves requests. After Sagents.Supervisor so OTP stops the listener
      # first and the registry is still alive for whatever is in flight.
      AgentsDemoWeb.Endpoint,
      # Last, so OTP stops it FIRST: its terminate/2 flips readiness to false
      # and waits, while the Endpoint above is still up to report it. Any
      # earlier position and the wait happens behind a stopped listener, where
      # the load balancer cannot observe it.
      {AgentsDemo.Drain, delay: drain_delay()}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentsDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Zero in dev and test. A drain delay that fires on every Ctrl-C is a delay
  # someone disables in week two, and then it is not there in production either.
  defp drain_delay do
    Application.get_env(:agents_demo, :drain_delay_ms, 0)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentsDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule AgentsDemoWeb.HealthController do
  @moduledoc """
  Liveness and readiness probes for the platform running this app.

  The two are answered by different questions and must not be wired to the
  same source.

  `alive/2` asks whether the BEAM is up. It never consults Sagents, because the
  correct response to a failure is a restart, and a node that is merely draining
  must not be restarted.

  `ready/2` asks whether this node can host and route agent sessions. It goes
  false the moment `Sagents.Supervisor` stops, which is *before* the BEAM exits:
  the node keeps accepting connections for the rest of the platform's grace
  period while every agent lookup on it fails. A load balancer still routing
  here during that window sends requests to the one node that cannot serve them,
  while every other node can.

  See `Sagents.ready?/0` and the Sagents `docs/deployment.md` guide for the full
  shutdown sequence.
  """
  use AgentsDemoWeb, :controller

  @doc """
  Liveness. 200 for as long as the BEAM answers at all.
  """
  def alive(conn, _params), do: send_resp(conn, 200, "ok")

  @doc """
  Readiness. 503 while this node cannot host or route agent sessions.

  503 rather than 500: the request is fine, this node just is not the place to
  serve it. That is the status clients and load balancers already know how to
  retry.
  """
  def ready(conn, _params) do
    if Sagents.ready?() do
      send_resp(conn, 200, "ok")
    else
      send_resp(conn, 503, "draining")
    end
  end
end

defmodule AgentsDemoWeb.DrainReadinessTest do
  @moduledoc """
  End-to-end cover for the drain window: the period after `Sagents.Supervisor`
  stops and before the BEAM exits, when the node still accepts connections but
  can serve no agent request.

  Nothing else in the suite enters that state, and it is the state every rolling
  deploy passes through.
  """
  use AgentsDemoWeb.ConnCase, async: false

  test "readiness reports the drain window that liveness must not", %{conn: conn} do
    assert Sagents.ready?()
    assert response(get(conn, ~p"/health/ready"), 200) == "ok"

    :ok = Supervisor.terminate_child(AgentsDemo.Supervisor, Sagents.Supervisor)

    refute Sagents.ready?()
    assert response(get(build_conn(), ~p"/health/ready"), 503) == "draining"

    # Liveness stays 200. A draining node is not unhealthy, and the platform's
    # response to a failed liveness probe is a restart.
    assert response(get(build_conn(), ~p"/health/alive"), 200) == "ok"

    # The reason the mount path is guarded on Sagents.ready?/0 rather than
    # relying on this call's own catch clause.
    assert_raise Sagents.RegistryUnavailableError, fn ->
      Sagents.AgentServer.get_status("conversation-1")
    end

    {:ok, _pid} = Supervisor.restart_child(AgentsDemo.Supervisor, Sagents.Supervisor)

    assert Sagents.ready?()
    assert response(get(build_conn(), ~p"/health/ready"), 200) == "ok"
  end
end

defmodule AgentsDemoWeb.HealthControllerTest do
  use AgentsDemoWeb.ConnCase, async: true
  use Mimic

  describe "GET /health/alive" do
    test "answers 200 without authentication", %{conn: conn} do
      conn = get(conn, ~p"/health/alive")
      assert response(conn, 200) == "ok"
    end

    test "answers 200 even when the node cannot host agents", %{conn: conn} do
      # Liveness must not follow readiness. A draining node is not unhealthy,
      # and the platform's response to a failed liveness probe is a restart.
      stub(Sagents, :ready?, fn -> false end)

      conn = get(conn, ~p"/health/alive")
      assert response(conn, 200) == "ok"
    end
  end

  describe "GET /health/ready" do
    test "answers 200 while this node can host agents", %{conn: conn} do
      conn = get(conn, ~p"/health/ready")
      assert response(conn, 200) == "ok"
    end

    test "answers 503 while this node is draining", %{conn: conn} do
      stub(Sagents, :ready?, fn -> false end)

      conn = get(conn, ~p"/health/ready")
      assert response(conn, 503) == "draining"
    end

    test "answers without a session or an Accept header", %{conn: conn} do
      # Probes send neither. The route is in no pipeline so that neither is
      # required: content negotiation would answer 406 and read as unhealthy.
      conn =
        conn
        |> Plug.Conn.delete_req_header("accept")
        |> get(~p"/health/ready")

      assert response(conn, 200) == "ok"
    end
  end
end

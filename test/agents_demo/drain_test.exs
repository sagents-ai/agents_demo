defmodule AgentsDemo.DrainTest do
  @moduledoc """
  Cover for the mechanism that keeps a load balancer from routing to a node
  whose Sagents tree is about to stop.

  The properties here are the ones that fail silently: a flag read that
  deadlocks, a `shutdown` timeout that kills the wait partway through, a
  readiness endpoint that only learns about the drain once it is too late to
  matter. None of them produce an error, and all of them mean the drain does
  not happen.
  """
  use AgentsDemoWeb.ConnCase, async: false

  alias AgentsDemo.Drain

  @delay 500

  setup do
    on_exit(fn -> :persistent_term.put({Drain, :draining?}, false) end)
    :ok
  end

  describe "child_spec/1" do
    test "derives a shutdown timeout that outlasts the delay" do
      # The GenServer default is 5_000. A 20s drain under it is brutal-killed
      # partway through terminate/2, with nothing to indicate it happened.
      assert %{shutdown: shutdown} = Drain.child_spec(delay: :timer.seconds(20))
      assert shutdown > :timer.seconds(20)
    end

    test "a zero delay still leaves room for terminate/2" do
      assert %{shutdown: shutdown} = Drain.child_spec([])
      assert shutdown > 0
    end
  end

  describe "the drain flag" do
    test "reads false while the node is serving normally" do
      refute Drain.draining?()
    end

    test "flips to true before the wait, not after it" do
      # The whole point of :persistent_term over GenServer state: during
      # terminate/2 the process is out of its receive loop, so a
      # GenServer.call/2 would block for the length of the drain and then exit.
      # The readiness endpoint has to keep answering during exactly that window.
      pid = start_isolated_drain()
      refute Drain.draining?()

      begin_shutdown(pid)

      assert eventually(fn -> Drain.draining?() end),
             "the flag should be set at the start of terminate/2"

      assert Process.alive?(pid),
             "the flag flipped only after the wait finished, which is too late"
    end

    test "the process does eventually stop" do
      pid = start_isolated_drain()
      ref = Process.monitor(pid)

      begin_shutdown(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, @delay * 8
    end
  end

  describe "readiness during the drain" do
    test "reports 503 while the Sagents tree is still fully up" do
      # This is the property a Sagents.ready?/0-only endpoint cannot have, and
      # it is the one the load balancer needs. The registry is alive and
      # answering here; the node reports itself unroutable anyway.
      pid = start_isolated_drain()
      begin_shutdown(pid)
      assert eventually(fn -> Drain.draining?() end)

      assert Sagents.ready?(), "the Sagents tree should still be up at this point"

      assert response(get(build_conn(), ~p"/health/ready"), 503) == "draining"
    end

    test "liveness stays 200 through the drain" do
      # A draining node is not unhealthy. A platform's response to a failed
      # liveness probe is a restart, which is the wrong move here.
      pid = start_isolated_drain()
      begin_shutdown(pid)
      assert eventually(fn -> Drain.draining?() end)

      assert response(get(build_conn(), ~p"/health/alive"), 200) == "ok"
    end
  end

  # The application already runs a Drain under its own name, so tests drive a
  # second one. The flag is deliberately node-level rather than per-process:
  # "this node is shutting down" is not a fact that varies by instance.
  defp start_isolated_drain do
    {:ok, pid} = Drain.start_link(delay: @delay, name: :drain_under_test)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # GenServer.stop/3 blocks until terminate/2 returns, which is the whole drain.
  # Running it elsewhere leaves this process free to observe the flag mid-wait,
  # which is exactly what the readiness endpoint does in production.
  defp begin_shutdown(pid) do
    spawn(fn -> GenServer.stop(pid, :shutdown, :infinity) end)
  end

  defp eventually(fun, attempts \\ 30) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end
end

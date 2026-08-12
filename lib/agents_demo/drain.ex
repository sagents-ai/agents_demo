defmodule AgentsDemo.Drain do
  @moduledoc """
  Holds shutdown open long enough for the load balancer to observe readiness
  going false and stop routing here.

  ## Why a delay is needed at all

  `Sagents.ready?/0` goes false when `Sagents.Supervisor` stops. By then the
  load balancer has already been routing to this node for the whole shutdown,
  and every request it sent will fail: the node keeps its listener open for the
  rest of the platform's grace period, but no agent lookup on it can succeed.

  The platform needs to be told *before* that, so it has time to poll the
  readiness endpoint, observe the change, and update its routing table. This
  process owns the flag that says so, and the sleep is what gives the polling
  time to happen.

  ## Why it is listed last

  OTP stops children in reverse order, so last means `terminate/2` runs first,
  while `AgentsDemoWeb.Endpoint` is still serving and can still answer
  `/health/ready`. Any earlier position and the sleep happens behind a stopped
  listener, where nothing can observe the flag it just set.

  ## Why the flag is not in this process's state

  During `terminate/2` this GenServer is out of its receive loop. A
  `GenServer.call/2` from the readiness endpoint would block for the entire
  sleep and then exit when the process dies. `:persistent_term` is read
  directly by the caller, so the endpoint keeps answering while this process
  waits.
  """
  use GenServer

  require Logger

  @flag {__MODULE__, :draining?}

  @doc """
  Whether this node has begun shutting down.

  Safe to call from a request: it reads `:persistent_term` rather than talking
  to this process.
  """
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@flag, false)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    delay = Keyword.get(opts, :delay, 0)
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [[delay: delay, name: name]]},
      # Must exceed the delay. The default of 5_000 would brutal-kill this
      # process partway through terminate/2, and the drain would silently not
      # happen.
      shutdown: delay + :timer.seconds(5)
    }
  end

  @impl true
  def init(opts) do
    # Without this, terminate/2 is not called on supervisor shutdown at all.
    Process.flag(:trap_exit, true)
    :persistent_term.put(@flag, false)
    {:ok, Keyword.get(opts, :delay, 0)}
  end

  @impl true
  def terminate(_reason, delay) do
    :persistent_term.put(@flag, true)

    if delay > 0 do
      Logger.info("draining: readiness is now false, waiting #{delay}ms before shutdown")
      Process.sleep(delay)
    end

    :ok
  end
end

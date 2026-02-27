defmodule AgentsDemo.Middleware.InjectCurrentTime do
  @moduledoc """
  Middleware that injects the current date and user timezone into the system prompt,
  and stores the timezone in state metadata for tool access.

  The date is computed once when the agent is created via `system_prompt/1`, making it
  cache-friendly (the system prompt stays stable for the session). The timezone is also
  stored in state metadata via `on_server_start/2` so other middleware tools can access it
  via `State.get_metadata(context.state, "timezone")` from the very first request.

  ## Configuration

  - `:timezone` - IANA timezone string (e.g., "America/Denver"). Defaults to "UTC".

  ## Example

      middleware = [
        {AgentsDemo.Middleware.InjectCurrentTime, [timezone: "America/Denver"]},
        # ... other middleware
      ]
  """
  @behaviour Sagents.Middleware

  alias Sagents.State

  require Logger

  @impl true
  def init(opts) do
    timezone = Keyword.get(opts, :timezone, "UTC")

    # Validate timezone is a valid IANA timezone
    timezone =
      if valid_timezone?(timezone) do
        timezone
      else
        Logger.warning("InjectCurrentTime: Invalid timezone '#{timezone}', falling back to UTC")

        "UTC"
      end

    {:ok, %{timezone: timezone}}
  end

  @impl true
  def system_prompt(config) do
    date =
      DateTime.utc_now()
      |> DateTime.shift_zone!(config.timezone)
      |> Calendar.strftime("%a, %Y-%m-%d %Z")

    """
    ## Current Date
    Today's date is #{date}. The user's timezone is #{config.timezone}.
    """
  end

  @impl true
  def on_server_start(state, config) do
    # Store timezone in state metadata at startup so all middleware tools can
    # access it via State.get_metadata(context.state, "timezone") from the
    # first request, regardless of middleware ordering.
    {:ok, State.put_metadata(state, "timezone", config.timezone)}
  end

  defp valid_timezone?(timezone) when is_binary(timezone) do
    case DateTime.now(timezone) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp valid_timezone?(_), do: false
end

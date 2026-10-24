defmodule AgentsDemo.Middleware.ManagedDevicesMiddleware do
  @moduledoc """
  A tool search namespace: an IT operations inventory of managed devices.

  The middleware declares the `"devices"` namespace with `tool_search/1`.
  With `Sagents.Middleware.ToolSearch` in the stack, its tools are declared on
  every request but kept out of the model's context until the model searches
  for them, and the transcript shows each search as a "tool_search" row.

  The inventory is fixed demo data, so a conversation can exercise loading
  without any real infrastructure: ask "How many devices are at the hq site?"
  or "Restart the printer in the warehouse".
  """
  @behaviour Sagents.Middleware

  alias LangChain.Function

  @devices [
    %{"id" => "dev-101", "site" => "hq", "kind" => "laptop", "name" => "Finance laptop 1"},
    %{"id" => "dev-102", "site" => "hq", "kind" => "laptop", "name" => "Finance laptop 2"},
    %{"id" => "dev-103", "site" => "hq", "kind" => "printer", "name" => "Lobby printer"},
    %{"id" => "dev-201", "site" => "warehouse", "kind" => "scanner", "name" => "Dock scanner"},
    %{"id" => "dev-202", "site" => "warehouse", "kind" => "printer", "name" => "Label printer"}
  ]

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def tool_search(_config) do
    [
      namespace: "devices",
      description: "List, inspect, and restart the managed devices at a site (hq or warehouse)."
    ]
  end

  # Sent with the system prompt from the first request, before any device tool
  # is loaded, so it says when the namespace is worth loading rather than how
  # to call its tools.
  @impl true
  def system_prompt(_config) do
    """
    ## Managed Devices
    When the user asks about laptops, printers, scanners, or other devices at a site, load
    the devices tools and answer from them. Never guess device counts or states.
    """
  end

  @impl true
  def tools(_config), do: [list_tool(), get_tool(), restart_tool()]

  defp list_tool do
    Function.new!(%{
      name: "devices_list",
      display_text: "Listing devices",
      description: "List the managed devices at a site, with the device count.",
      parameters_schema: %{
        type: "object",
        properties: %{site: %{type: "string", enum: ["hq", "warehouse"]}},
        required: ["site"]
      },
      function: fn %{"site" => site}, _context ->
        devices = Enum.filter(@devices, &(&1["site"] == site))
        {:ok, Jason.encode!(%{"site" => site, "count" => length(devices), "devices" => devices})}
      end
    })
  end

  defp get_tool do
    Function.new!(%{
      name: "devices_get",
      display_text: "Looking up device",
      description: "Get one managed device by its id.",
      parameters_schema: %{
        type: "object",
        properties: %{id: %{type: "string", description: "The device id, such as dev-101."}},
        required: ["id"]
      },
      function: fn %{"id" => id}, _context ->
        case Enum.find(@devices, &(&1["id"] == id)) do
          nil -> {:error, "No device with id #{id}."}
          device -> {:ok, Jason.encode!(Map.put(device, "status", "online"))}
        end
      end
    })
  end

  defp restart_tool do
    Function.new!(%{
      name: "devices_restart",
      display_text: "Restarting device",
      description: "Restart a managed device by its id.",
      parameters_schema: %{
        type: "object",
        properties: %{id: %{type: "string", description: "The device id, such as dev-101."}},
        required: ["id"]
      },
      function: fn %{"id" => id}, _context ->
        case Enum.find(@devices, &(&1["id"] == id)) do
          nil -> {:error, "No device with id #{id}."}
          device -> {:ok, "Restart sent to #{device["name"]} (#{id})."}
        end
      end
    })
  end
end

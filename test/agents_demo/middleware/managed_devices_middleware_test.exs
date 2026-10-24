defmodule AgentsDemo.Middleware.ManagedDevicesMiddlewareTest do
  use ExUnit.Case, async: false

  alias AgentsDemo.Agents.Factory
  alias AgentsDemo.Agents.FactoryConfig
  alias AgentsDemo.Middleware.ManagedDevicesMiddleware
  alias LangChain.Function
  alias LangChain.NativeTool
  alias Sagents.AbilitySets

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test_api_key_12345")
    {:ok, agent, []} = Factory.create_agent("tool-search-demo", %FactoryConfig{})
    %{agent: agent}
  end

  defp tool(tools, name), do: Enum.find(tools, &(&1.name == name))

  describe "the factory's tool search" do
    test "every mode sends the search tool and the deferred device tools", %{agent: agent} do
      for set <- [nil, "pirate", "kung_foo"] do
        tools = AbilitySets.effective(agent, set).tools

        assert %NativeTool{name: "tool_search"} = tool(tools, "tool_search")

        for name <- ["devices_list", "devices_get", "devices_restart"] do
          function = tool(tools, name)
          assert Function.deferred?(function)
          assert Function.namespace(function) == "devices"
        end

        # The rails stay visible.
        refute Function.deferred?(tool(tools, "write_todos"))
      end
    end

    test "the prompt lists the devices namespace and keeps the middleware's fragment", %{
      agent: agent
    } do
      prompt = agent.assembled_system_prompt

      assert prompt =~ "Some tools load on demand."
      assert prompt =~ "- devices: List, inspect, and restart the managed devices"
      assert prompt =~ "## Managed Devices"
    end

    test "the index records the namespace", %{agent: agent} do
      assert %{
               "devices" => %{
                 tools: ["devices_list", "devices_get", "devices_restart"],
                 entry_ids: [ManagedDevicesMiddleware]
               }
             } = agent.tool_search_index
    end
  end

  describe "the device tools" do
    setup do
      {:ok, config} = ManagedDevicesMiddleware.init([])
      %{tools: ManagedDevicesMiddleware.tools(config)}
    end

    test "devices_list counts a site's devices", %{tools: tools} do
      assert {:ok, json} = tool(tools, "devices_list").function.(%{"site" => "hq"}, %{})
      assert %{"site" => "hq", "count" => 3} = Jason.decode!(json)
    end

    test "devices_get and devices_restart find a device by id", %{tools: tools} do
      assert {:ok, json} = tool(tools, "devices_get").function.(%{"id" => "dev-202"}, %{})
      assert %{"name" => "Label printer", "status" => "online"} = Jason.decode!(json)

      assert {:ok, "Restart sent to Label printer (dev-202)."} =
               tool(tools, "devices_restart").function.(%{"id" => "dev-202"}, %{})

      assert {:error, "No device with id dev-999."} =
               tool(tools, "devices_restart").function.(%{"id" => "dev-999"}, %{})
    end
  end
end

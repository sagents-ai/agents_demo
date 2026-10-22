defmodule AgentsDemo.Middleware.AbilitySetsTest do
  use ExUnit.Case, async: false

  alias AgentsDemo.Agents.Factory
  alias AgentsDemo.Agents.FactoryConfig
  alias AgentsDemo.Middleware.KungFooMiddleware
  alias AgentsDemo.Middleware.PirateMiddleware
  alias Sagents.AbilitySets

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test_api_key_12345")
    {:ok, agent, []} = Factory.create_agent("ability-sets-demo", %FactoryConfig{})
    %{agent: agent}
  end

  defp tool_names(tools), do: Enum.map(tools, & &1.name)

  describe "PirateMiddleware" do
    test "set_sail answers with one of the crew's reports" do
      {:ok, config} = PirateMiddleware.init([])
      [set_sail] = PirateMiddleware.tools(config)

      assert set_sail.name == "set_sail"
      assert {:ok, report} = set_sail.function.(%{}, %{})
      assert report in PirateMiddleware.responses()
    end
  end

  describe "factory ability sets" do
    test "no mode is active in a new conversation", %{agent: agent} do
      effective = AbilitySets.effective(agent, nil)

      assert "switch_mode" in tool_names(effective.tools)
      refute "set_sail" in tool_names(effective.tools)
      refute effective.system_prompt =~ "Pirate Mode"
      refute effective.system_prompt =~ "Kung Foo Mode"
      assert agent.assembled_system_prompt == effective.system_prompt
    end

    test "pirate mode adds the persona and set_sail", %{agent: agent} do
      effective = AbilitySets.effective(agent, "pirate")

      assert "set_sail" in tool_names(effective.tools)
      assert effective.system_prompt =~ PirateMiddleware.system_prompt(%{})
      refute effective.system_prompt =~ "Kung Foo Mode"
    end

    test "kung_foo mode adds the persona and no tools", %{agent: agent} do
      effective = AbilitySets.effective(agent, "kung_foo")

      assert tool_names(effective.tools) == tool_names(AbilitySets.effective(agent, nil).tools)
      assert effective.system_prompt =~ KungFooMiddleware.system_prompt(%{})
      refute effective.system_prompt =~ "Pirate Mode"
    end

    test "rail prompts are present in every mode", %{agent: agent} do
      rails_prompt = AbilitySets.effective(agent, nil).system_prompt

      for set <- ["pirate", "kung_foo"] do
        prompt = AbilitySets.effective(agent, set).system_prompt
        assert prompt =~ "## Web Lookup Tool"
        assert prompt =~ "## Current Date"

        assert String.starts_with?(
                 prompt,
                 String.split(rails_prompt, "## Modes") |> hd()
               )
      end
    end
  end
end

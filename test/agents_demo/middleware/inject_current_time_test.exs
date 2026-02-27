defmodule AgentsDemo.Middleware.InjectCurrentTimeTest do
  use ExUnit.Case, async: true

  alias AgentsDemo.Middleware.InjectCurrentTime
  alias Sagents.State

  describe "init/1" do
    test "creates config with provided timezone" do
      {:ok, config} = InjectCurrentTime.init(timezone: "America/Denver")
      assert config.timezone == "America/Denver"
    end

    test "defaults to UTC when no timezone provided" do
      {:ok, config} = InjectCurrentTime.init([])
      assert config.timezone == "UTC"
    end

    test "falls back to UTC for invalid timezone" do
      {:ok, config} = InjectCurrentTime.init(timezone: "Invalid/Timezone")
      assert config.timezone == "UTC"
    end

    test "falls back to UTC for nil timezone" do
      {:ok, config} = InjectCurrentTime.init(timezone: nil)
      assert config.timezone == "UTC"
    end

    test "accepts various valid timezones" do
      timezones = [
        "America/New_York",
        "Europe/London",
        "Asia/Tokyo",
        "Australia/Sydney",
        "Pacific/Auckland"
      ]

      for tz <- timezones do
        {:ok, config} = InjectCurrentTime.init(timezone: tz)
        assert config.timezone == tz, "Expected #{tz} to be accepted"
      end
    end
  end

  describe "system_prompt/1" do
    test "includes the current date and configured timezone" do
      {:ok, config} = InjectCurrentTime.init(timezone: "America/Denver")
      prompt = InjectCurrentTime.system_prompt(config)

      assert is_binary(prompt)
      assert String.contains?(prompt, "America/Denver")
      assert String.contains?(prompt, "Today's date is")
      # Should contain a date pattern like "Wed, 2026-02-26"
      assert Regex.match?(~r/\d{4}-\d{2}-\d{2}/, prompt), "Should contain a date"
    end

    test "uses UTC when configured with UTC" do
      {:ok, config} = InjectCurrentTime.init([])
      prompt = InjectCurrentTime.system_prompt(config)

      assert String.contains?(prompt, "UTC")
    end
  end

  describe "on_server_start/2" do
    test "stores timezone in state metadata" do
      {:ok, config} = InjectCurrentTime.init(timezone: "America/Denver")
      state = State.new!(%{messages: []})

      {:ok, updated_state} = InjectCurrentTime.on_server_start(state, config)

      assert State.get_metadata(updated_state, "timezone") == "America/Denver"
    end

    test "stores UTC timezone in state metadata by default" do
      {:ok, config} = InjectCurrentTime.init([])
      state = State.new!(%{messages: []})

      {:ok, updated_state} = InjectCurrentTime.on_server_start(state, config)

      assert State.get_metadata(updated_state, "timezone") == "UTC"
    end

    test "does not modify messages" do
      {:ok, config} = InjectCurrentTime.init(timezone: "America/Denver")

      state =
        State.new!(%{
          messages: [
            LangChain.Message.new_user!("Hello"),
            LangChain.Message.new_assistant!("Hi there")
          ]
        })

      {:ok, updated_state} = InjectCurrentTime.on_server_start(state, config)

      assert updated_state.messages == state.messages
    end
  end
end

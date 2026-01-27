defmodule AgentsDemo.Middleware.InjectCurrentTimeTest do
  use ExUnit.Case, async: true

  alias AgentsDemo.Middleware.InjectCurrentTime
  alias Sagents.State
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  # Helper to extract text content from a message (handles ContentPart lists)
  defp get_text_content(%Message{content: content}) when is_list(content) do
    content
    |> Enum.find_value(fn
      %ContentPart{type: :text, content: text} -> text
      _ -> nil
    end)
  end

  defp get_text_content(%Message{content: content}) when is_binary(content), do: content

  # Helper to check if content starts with a string (handles ContentPart lists)
  defp content_starts_with?(%Message{} = msg, prefix) do
    case get_text_content(msg) do
      nil -> false
      text -> String.starts_with?(text, prefix)
    end
  end

  # Helper to check if content contains a string (handles ContentPart lists)
  defp content_contains?(%Message{} = msg, substring) do
    case get_text_content(msg) do
      nil -> false
      text -> String.contains?(text, substring)
    end
  end

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
    test "returns explanation of timestamp format" do
      {:ok, config} = InjectCurrentTime.init([])
      prompt = InjectCurrentTime.system_prompt(config)

      assert is_binary(prompt)
      assert String.contains?(prompt, "<current_timestamp>")
      assert String.contains?(prompt, "temporal context")
    end
  end

  describe "before_model/2 with string content" do
    setup do
      {:ok, config} = InjectCurrentTime.init(timezone: "UTC")
      {:ok, config: config}
    end

    test "prepends timestamp to the last user message", %{config: config} do
      state =
        State.new!(%{
          messages: [
            Message.new_user!("First message"),
            Message.new_assistant!("Response"),
            Message.new_user!("Second message")
          ]
        })

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      # First user message should NOT be modified
      first_msg = Enum.at(updated_state.messages, 0)
      refute content_starts_with?(first_msg, "<current_timestamp>")
      assert content_contains?(first_msg, "First message")

      # Assistant message should NOT be modified
      assistant_msg = Enum.at(updated_state.messages, 1)
      assert content_contains?(assistant_msg, "Response")

      # Last user message SHOULD be modified
      last_msg = Enum.at(updated_state.messages, 2)
      assert content_starts_with?(last_msg, "<current_timestamp>")
      assert content_contains?(last_msg, "Second message")
    end

    test "does not modify messages when there are no user messages", %{config: config} do
      state =
        State.new!(%{
          messages: [
            Message.new_system!("System prompt"),
            Message.new_assistant!("Response")
          ]
        })

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      # Messages should be unchanged
      assert updated_state.messages == state.messages
    end

    test "handles state with only one user message", %{config: config} do
      state =
        State.new!(%{
          messages: [
            Message.new_user!("Only message")
          ]
        })

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      [msg] = updated_state.messages
      assert content_starts_with?(msg, "<current_timestamp>")
      assert content_contains?(msg, "Only message")
    end

    test "handles empty messages list", %{config: config} do
      state = State.new!(%{messages: []})

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      assert updated_state.messages == []
    end
  end

  describe "before_model/2 with multi-part content" do
    setup do
      {:ok, config} = InjectCurrentTime.init(timezone: "UTC")
      {:ok, config: config}
    end

    test "prepends timestamp to the first text part in multi-part content", %{config: config} do
      content_parts = [
        ContentPart.text!("User text"),
        ContentPart.new!(%{type: :image_url, content: "https://example.com/image.png"})
      ]

      # Create user message with placeholder, then replace content
      user_msg = %{Message.new_user!("placeholder") | content: content_parts}

      state = State.new!(%{messages: [user_msg]})

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      [msg] = updated_state.messages
      [first_part | _rest] = msg.content

      assert first_part.type == :text
      assert String.starts_with?(first_part.content, "<current_timestamp>")
      assert String.contains?(first_part.content, "User text")
    end
  end

  describe "timestamp format" do
    test "timestamp format is correct for UTC" do
      {:ok, config} = InjectCurrentTime.init(timezone: "UTC")

      state =
        State.new!(%{
          messages: [Message.new_user!("Test")]
        })

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      [msg] = updated_state.messages
      content = get_text_content(msg)

      # Extract timestamp from content
      case Regex.run(~r/<current_timestamp>(.+?)<\/current_timestamp>/, content) do
        [_, timestamp] ->
          # Should contain day of week, date, time, AM/PM, and timezone
          assert String.contains?(timestamp, "UTC")

          assert Regex.match?(~r/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),/, timestamp),
                 "Should start with day abbreviation"

          assert Regex.match?(~r/\d{4}-\d{2}-\d{2}/, timestamp), "Should contain date"
          assert Regex.match?(~r/\d{1,2}:\d{2}:\d{2}/, timestamp), "Should contain time"
          assert Regex.match?(~r/(AM|PM)/, timestamp), "Should contain AM/PM"

        nil ->
          flunk("Timestamp not found in content")
      end
    end

    test "timestamp reflects configured timezone" do
      {:ok, config} = InjectCurrentTime.init(timezone: "America/New_York")

      state =
        State.new!(%{
          messages: [Message.new_user!("Test")]
        })

      {:ok, updated_state} = InjectCurrentTime.before_model(state, config)

      [msg] = updated_state.messages
      content = get_text_content(msg)

      # Extract timestamp and verify it contains the timezone abbreviation
      # Note: The exact abbreviation depends on DST (EST vs EDT)
      case Regex.run(~r/<current_timestamp>(.+?)<\/current_timestamp>/, content) do
        [_, timestamp] ->
          # Should contain either EST or EDT
          assert String.contains?(timestamp, "E") or String.contains?(timestamp, "America"),
                 "Timestamp should contain Eastern timezone info: #{timestamp}"

        nil ->
          flunk("Timestamp not found in content")
      end
    end
  end
end

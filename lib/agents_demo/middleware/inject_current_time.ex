defmodule AgentsDemo.Middleware.InjectCurrentTime do
  @moduledoc """
  Middleware that prepends current timestamp to user messages.

  The timestamp is only visible to the LLM, not displayed in the chat UI.
  This is useful for giving the AI temporal awareness, especially when
  resuming conversations from previous sessions.

  ## How It Works

  The `before_model/2` hook runs AFTER messages are saved to the database
  and displayed in the UI, but BEFORE they're sent to the LLM. This means:

  1. User types: "What's the weather like today?"
  2. Message saved to DB and shown in UI: "What's the weather like today?"
  3. `before_model/2` prepends timestamp for LLM only
  4. LLM receives: "<current_timestamp>2026-01-17 5:09:23 PM MST</current_timestamp>\n\nWhat's the weather like today?"

  ## Configuration

  - `:timezone` - IANA timezone string (e.g., "America/Denver"). Defaults to "UTC".

  ## Example

      middleware = [
        {AgentsDemo.Middleware.InjectCurrentTime, [timezone: "America/Denver"]},
        # ... other middleware
      ]
  """
  @behaviour Sagents.Middleware

  alias LangChain.Message

  require Logger

  @impl true
  def init(opts) do
    timezone = Keyword.get(opts, :timezone, "UTC")

    # Validate timezone is a valid IANA timezone
    timezone =
      if valid_timezone?(timezone) do
        timezone
      else
        Logger.warning(
          "InjectCurrentTime: Invalid timezone '#{timezone}', falling back to UTC"
        )

        "UTC"
      end

    {:ok, %{timezone: timezone}}
  end

  @impl true
  def system_prompt(_config) do
    """
    User messages include a <current_timestamp> tag showing when the message was sent.
    Use this to understand temporal context, especially in resumed conversations.
    """
  end

  @impl true
  def tools(_config), do: []

  @impl true
  def state_schema, do: []

  @impl true
  def before_model(state, config) do
    # Find and modify user messages to prepend timestamp
    # We only modify the LAST user message to avoid re-timestamping historical messages
    updated_messages = prepend_timestamp_to_last_user_message(state.messages, config.timezone)

    {:ok, %{state | messages: updated_messages}}
  end

  @impl true
  def after_model(state, _config), do: {:ok, state}

  @impl true
  def handle_message(_message, state, _config), do: {:ok, state}

  @impl true
  def on_server_start(state, _config), do: {:ok, state}

  # Private helpers

  defp prepend_timestamp_to_last_user_message(messages, timezone) do
    # Find the index of the last user message
    last_user_index =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _idx} -> msg.role == :user end)
      |> List.last()
      |> case do
        {_msg, idx} -> idx
        nil -> nil
      end

    if last_user_index do
      List.update_at(messages, last_user_index, fn msg ->
        prepend_timestamp(msg, timezone)
      end)
    else
      messages
    end
  end

  defp prepend_timestamp(%Message{} = message, timezone) do
    timestamp = format_current_time(timezone)

    # Handle both string content and list content (ContentPart)
    # Note: Modern LangChain converts all content to ContentPart lists
    new_content =
      case message.content do
        content when is_binary(content) ->
          ~s|<current_timestamp>#{timestamp}</current_timestamp>\n\n#{content}|

        content_parts when is_list(content_parts) ->
          # For ContentPart list, prepend to the first text part
          prepend_to_content_parts(content_parts, timestamp)

        other ->
          # Unknown format, leave as-is
          Logger.warning("InjectCurrentTime: Unknown content format: #{inspect(other)}")
          other
      end

    %{message | content: new_content}
  end

  defp prepend_to_content_parts(parts, timestamp) do
    # Find first text ContentPart and prepend timestamp to it
    {updated, found} =
      Enum.map_reduce(parts, false, fn part, found_text ->
        cond do
          found_text ->
            {part, true}

          match?(%LangChain.Message.ContentPart{type: :text}, part) ->
            new_text = ~s|<current_timestamp>#{timestamp}</current_timestamp>\n\n#{part.content}|

            {%{part | content: new_text}, true}

          true ->
            {part, false}
        end
      end)

    if found do
      updated
    else
      # No text part found, prepend a new text part
      timestamp_part = LangChain.Message.ContentPart.text!(
        "<current_timestamp>#{timestamp}</current_timestamp>\n\n"
      )

      [timestamp_part | parts]
    end
  end

  defp format_current_time(timezone) do
    DateTime.utc_now()
    |> DateTime.shift_zone!(timezone)
    |> Calendar.strftime("%a, %Y-%m-%d %-I:%M:%S %p %Z")
  end

  defp valid_timezone?(timezone) when is_binary(timezone) do
    case DateTime.now(timezone) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp valid_timezone?(_), do: false
end

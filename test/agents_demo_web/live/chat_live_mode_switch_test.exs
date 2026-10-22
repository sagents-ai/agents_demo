defmodule AgentsDemoWeb.ChatLiveModeSwitchTest do
  @moduledoc """
  A mode switch, end to end, through a real LiveView, a real AgentServer, and a
  mocked LLM: the model is told which tools the switch added, and the user sees
  the mode's announcement in the transcript between the switch and the reply.
  """
  use AgentsDemoWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures

  alias AgentsDemo.Conversations
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Message.ToolCall

  # The agent runs in its own Task, so Mimic has to be global.
  setup :set_mimic_global

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test_api_key_12345")
    user = user_fixture()
    %{user: user, conn: log_in_user(build_conn(), user)}
  end

  defp wait_for_status(view, expected, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      assigns = :sys.get_state(view.pid).socket.assigns

      cond do
        assigns[:agent_status] == expected -> {:ok, assigns}
        System.monotonic_time(:millisecond) > deadline -> {:timeout, assigns[:agent_status]}
        true -> (fn -> Process.sleep(5) end).() && :continue
      end
    end)
    |> Enum.find(&(&1 != :continue))
  end

  defp submit(view, message) do
    view
    |> element("input[name='message']")
    |> render_change(%{message: message})

    view
    |> element("form[phx-submit='send_message']")
    |> render_submit(%{message: message})
  end

  defp user_texts(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.map(&ContentPart.content_to_string(&1.content))
  end

  defp tool_result_texts(messages) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.tool_results)
    |> Enum.map(&ContentPart.content_to_string(&1.content))
  end

  test "switching to pirate mode announces it to the model and the user", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")
    test_pid = self()

    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      cond do
        Enum.any?(user_texts(messages), &String.contains?(&1, "Generate and return the title")) ->
          {:ok, [Message.new_assistant!(%{content: "Pirates"})]}

        Enum.any?(messages, &(&1.role == :tool)) ->
          send(test_pid, {:tool_results, tool_result_texts(messages)})
          {:ok, [Message.new_assistant!("Ahoy, matey!")]}

        true ->
          switch =
            ToolCall.new!(%{
              call_id: "call_switch",
              name: "switch_mode",
              arguments: %{"mode" => "pirate"}
            })

          {:ok, [Message.new_assistant!(%{tool_calls: [switch]})]}
      end
    end)

    submit(view, "Talk like a pirate")
    assert {:ok, assigns} = wait_for_status(view, :idle)

    assert_received {:tool_results,
                     ["Switched to the Pirate mode. Tools now available: set_sail."]}

    rows = Conversations.load_display_messages(assigns.current_scope, assigns.conversation_id)
    texts = Enum.map(rows, &Map.get(&1.content, "text"))

    announcement_at =
      Enum.find_index(texts, &(&1 == "Hoisting the colors. Speaking as a pirate from here on."))

    reply_at = Enum.find_index(texts, &(&1 == "Ahoy, matey!"))
    switch_at = Enum.find_index(rows, &(&1.content["name"] == "switch_mode"))

    assert announcement_at, "expected the announcement in #{inspect(texts)}"
    assert switch_at, "expected a switch_mode tool call row"
    assert switch_at < announcement_at
    assert announcement_at < reply_at
  end
end

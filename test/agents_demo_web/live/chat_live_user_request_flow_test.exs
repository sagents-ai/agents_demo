defmodule AgentsDemoWeb.ChatLiveUserRequestFlowTest do
  @moduledoc """
  One request, end to end, through a real LiveView, a real AgentServer, and a
  mocked LLM: its rows are numbered as they stream in, the user request is
  recorded when it finishes, and the transcript folds its work away behind the
  final answer.
  """
  use AgentsDemoWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures

  alias AgentsDemo.Conversations
  alias AgentsDemo.Conversations.DisplayMessage
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

  defp with_usage(%Message{} = message, input, output) do
    usage = LangChain.TokenUsage.new!(%{input: input, output: output})
    %Message{message | metadata: Map.put(message.metadata || %{}, :usage, usage)}
  end

  test "a finished request is recorded and its work folds behind the answer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      cond do
        Enum.any?(user_texts(messages), &String.contains?(&1, "Generate and return the title")) ->
          {:ok, [Message.new_assistant!(%{content: "Planning"})]}

        Enum.any?(messages, &(&1.role == :tool)) ->
          {:ok, [with_usage(Message.new_assistant!("Your plan is ready."), 200, 20)]}

        true ->
          tool_call =
            ToolCall.new!(%{
              call_id: "call_plan",
              name: "write_todos",
              arguments: %{
                "merge" => false,
                "todos" => [%{"content" => "Step one", "id" => 1, "status" => "pending"}]
              }
            })

          {:ok,
           [
             with_usage(
               Message.new_assistant!(%{content: "Making a plan", tool_calls: [tool_call]}),
               100,
               10
             )
           ]}
      end
    end)

    submit(view, "Plan my day")
    assert {:ok, assigns} = wait_for_status(view, :idle)

    scope = assigns.current_scope
    conversation_id = assigns.conversation_id

    assert %{1 => user_request} = Conversations.user_requests_by_seq(scope, conversation_id)
    assert user_request.status == "completed"
    assert user_request.tool_calls == %{"write_todos" => 1}
    assert user_request.token_usage == %{"input" => 300, "output" => 30}

    rows = Conversations.load_display_messages(scope, conversation_id)
    assert rows != []
    assert Enum.all?(rows, &(&1.user_request_seq == 1))

    assert [%DisplayMessage{content: %{"text" => "Your plan is ready."}}] =
             Enum.filter(rows, & &1.user_request_final)

    assert has_element?(view, "#user-request-1-work summary", "Worked for")
    assert has_element?(view, "#user-request-1-work", "Making a plan")
    refute has_element?(view, "#user-request-1-work", "Your plan is ready.")
    assert has_element?(view, "#messages-list", "Your plan is ready.")
  end
end

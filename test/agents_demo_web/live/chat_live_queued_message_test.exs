defmodule AgentsDemoWeb.ChatLiveQueuedMessageTest do
  @moduledoc """
  Proves the "keep typing while the agent works" flow end to end, through a real
  LiveView, a real AgentServer, and a mocked LLM.

  Before the pending-message queue existed, sending during a run was a bug in
  three ways at once: `AgentServer.add_message/2` returned an error, the message
  was written into the rolling state and then destroyed when the canonical state
  replaced it, and the UI defended against all of that by disabling the input.

  What this test asserts is that all three go away together. The user can type
  during a run, the message is not lost, it reaches the model on the follow-up
  run as a `:user` turn, and no error is surfaced.
  """
  use AgentsDemoWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  # The agent runs in its own Task, so Mimic has to be global.
  setup :set_mimic_global

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test_api_key_12345")
    user = user_fixture()
    %{user: user, conn: log_in_user(build_conn(), user)}
  end

  defp wait_for_status(view, expected, timeout \\ 2_000) do
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

  # Submits without first waiting for :idle, which is the entire point here.
  defp submit_now(view, message) do
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

  test "a message typed while the agent is running is queued, not lost", %{conn: conn} do
    test_pid = self()
    {:ok, view, _html} = live(conn, ~p"/chat")

    # The first agent call blocks, holding the run open so the test can type
    # into a genuinely-running agent rather than racing a fast one.
    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      texts = user_texts(messages)

      cond do
        # The app generates a conversation title on its own model. It is not
        # part of the agent loop, so it must not be mistaken for the drained run.
        Enum.any?(texts, &String.contains?(&1, "Generate and return the title")) ->
          {:ok, [Message.new_assistant!(%{content: "A Long Task"})]}

        # The follow-up run, carrying the queued message.
        Enum.any?(texts, &String.contains?(&1, "SECOND")) ->
          send(test_pid, {:agent_call, texts, self()})
          {:ok, [Message.new_assistant!(%{content: "Acknowledged."})]}

        # The first run. Block, holding it open so the test types into a
        # genuinely-running agent rather than racing a fast one.
        true ->
          send(test_pid, {:agent_call, texts, self()})

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end

          {:ok, [Message.new_assistant!(%{content: "Working on the first thing."})]}
      end
    end)

    submit_now(view, "FIRST please do a long task")

    assert {:ok, _assigns} = wait_for_status(view, :running)
    assert_receive {:agent_call, _first_texts, run_pid}, 2_000

    # The input must be live while running. This is the UI half of the feature.
    # Match the attribute via CSS rather than a regex: the class list contains
    # Tailwind's `disabled:opacity-60` variants, which a naive regex matches.
    refute has_element?(view, "input[name='message'][disabled]")

    # Both controls are present while running, and they are independent. Stop
    # and send are different intentions; a user who has typed a correction must
    # still be able to stop the agent.
    assert has_element?(view, "#chat-stop-button")
    assert has_element?(view, "#chat-send-button")

    # The stop button must not be a submit button, or clicking it would fire
    # send_message as well as cancel_agent.
    assert has_element?(view, "#chat-stop-button[type='button']")
    assert has_element?(view, "#chat-send-button[type='submit']")

    # Type while the agent is working. Previously this was dropped by the
    # `loading` guard and rejected by AgentServer.
    submit_now(view, "SECOND actually also do this")

    # No error surfaced to the user.
    refute render(view) =~ "Failed to start agent"

    # The typed message appears in the transcript immediately, at queue time,
    # rather than a turn later.
    assert render(view) =~ "SECOND actually also do this"

    # Let the first run finish. The drain should start a second run by itself.
    send(run_pid, :release)

    # The queued text reaches the model on the follow-up run, as a :user turn.
    assert_receive {:agent_call, texts, _pid}, 5_000

    assert Enum.any?(texts, &String.contains?(&1, "SECOND")),
           "expected the queued message to reach the model, got: #{inspect(texts)}"

    assert {:ok, assigns} = wait_for_status(view, :idle, 5_000)

    # And it is in the conversation exactly once.
    queued_count =
      assigns[:agent_id]
      |> Sagents.AgentServer.get_state()
      |> Map.get(:messages)
      |> user_texts()
      |> Enum.count(&String.contains?(&1, "SECOND"))

    assert queued_count == 1
  end

  test "the agent can still be stopped while the user has text typed", %{conn: conn} do
    # The reason send and stop are two buttons rather than one that swaps roles.
    # With a single dual-purpose button, typing a correction removes the only
    # way to stop the agent, which is precisely the moment you want both.
    test_pid = self()
    {:ok, view, _html} = live(conn, ~p"/chat")

    stub(ChatAnthropic, :call, fn _model, messages, _tools ->
      texts = user_texts(messages)

      if Enum.any?(texts, &String.contains?(&1, "Generate and return the title")) do
        {:ok, [Message.new_assistant!(%{content: "A Long Task"})]}
      else
        send(test_pid, {:agent_call, texts, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        {:ok, [Message.new_assistant!(%{content: "Done."})]}
      end
    end)

    submit_now(view, "FIRST start something slow")

    assert {:ok, _assigns} = wait_for_status(view, :running)
    assert_receive {:agent_call, _texts, _pid}, 2_000

    # Type a correction but do not send it.
    view
    |> element("input[name='message']")
    |> render_change(%{message: "wait, stop"})

    # The stop control is still there, and still a plain button.
    assert has_element?(view, "#chat-stop-button[type='button']")

    render_click(element(view, "#chat-stop-button"))

    assert {:ok, _assigns} = wait_for_status(view, :cancelled, 5_000)
  end
end

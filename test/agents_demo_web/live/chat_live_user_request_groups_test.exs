defmodule AgentsDemoWeb.ChatLiveUserRequestGroupsTest do
  @moduledoc """
  A finished user request folds its work behind a "Worked for ..." summary with
  the final answer outside it; one still in progress shows everything.
  """
  use AgentsDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures
  import AgentsDemo.ConversationsFixtures

  alias AgentsDemo.Conversations

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    conversation = conversation_fixture(%{scope: scope})

    %{
      conn: log_in_user(build_conn(), user),
      scope: scope,
      conversation_id: conversation.id
    }
  end

  defp row(scope, conversation_id, seq, message_type, content_type, content) do
    {:ok, row} =
      Conversations.append_display_message(scope, conversation_id, %{
        message_type: message_type,
        content_type: content_type,
        content: content,
        user_request_seq: seq
      })

    row
  end

  test "a completed user request folds its work and keeps its answer visible", %{
    conn: conn,
    scope: scope,
    conversation_id: conversation_id
  } do
    row(scope, conversation_id, 1, "user", "text", %{"text" => "Find the policy"})
    row(scope, conversation_id, 1, "assistant", "text", %{"text" => "Looking it up"})

    answer =
      row(scope, conversation_id, 1, "assistant", "text", %{"text" => "Refunds take 30 days"})

    {:ok, _user_request} =
      Conversations.complete_user_request(
        scope,
        conversation_id,
        %{seq: 1, status: "completed", completed_at: DateTime.add(DateTime.utc_now(), 45)},
        [answer.id]
      )

    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{conversation_id}")

    assert has_element?(view, "#user-request-1-work summary", "Worked for")
    assert has_element?(view, "#user-request-1-work", "Looking it up")
    refute has_element?(view, "#user-request-1-work", "Refunds take 30 days")
    assert has_element?(view, "#messages-list", "Refunds take 30 days")
  end

  test "a user request still in progress shows everything without folding", %{
    conn: conn,
    scope: scope,
    conversation_id: conversation_id
  } do
    row(scope, conversation_id, 1, "user", "text", %{"text" => "Find the policy"})
    row(scope, conversation_id, 1, "assistant", "text", %{"text" => "Looking it up"})

    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{conversation_id}")

    refute has_element?(view, "#user-request-1-work")
    assert has_element?(view, "#messages-list", "Looking it up")
  end

  test "a cancelled user request says it stopped", %{
    conn: conn,
    scope: scope,
    conversation_id: conversation_id
  } do
    row(scope, conversation_id, 1, "user", "text", %{"text" => "Find the policy"})
    row(scope, conversation_id, 1, "assistant", "text", %{"text" => "Looking it up"})

    {:ok, _user_request} =
      Conversations.complete_user_request(
        scope,
        conversation_id,
        %{seq: 1, status: "cancelled", completed_at: DateTime.utc_now()},
        []
      )

    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{conversation_id}")

    assert has_element?(view, "#user-request-1-work summary", "Stopped after")
  end

  test "debug mode tags each row with its user request and final flag", %{
    conn: conn,
    scope: scope,
    conversation_id: conversation_id
  } do
    question = row(scope, conversation_id, 1, "user", "text", %{"text" => "Find the policy"})

    answer =
      row(scope, conversation_id, 1, "assistant", "text", %{"text" => "Refunds take 30 days"})

    {:ok, _user_request} =
      Conversations.complete_user_request(
        scope,
        conversation_id,
        %{seq: 1, status: "completed", completed_at: DateTime.utc_now()},
        [answer.id]
      )

    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{conversation_id}")
    refute has_element?(view, "#user-request-tag-#{answer.id}")

    render_click(view, "toggle_debug_mode", %{})

    assert has_element?(view, "#user-request-tag-#{question.id}", "request #1")
    refute has_element?(view, "#user-request-tag-#{question.id}", "final")
    assert has_element?(view, "#user-request-tag-#{answer.id}", "final")
    assert has_element?(view, "#messages-list", "Refunds take 30 days")
  end
end

defmodule AgentsDemo.ConversationsUserRequestsTest do
  use AgentsDemo.DataCase

  alias AgentsDemo.Conversations
  alias AgentsDemo.Conversations.{DisplayMessage, UserRequest}

  import AgentsDemo.AccountsFixtures
  import AgentsDemo.ConversationsFixtures

  setup do
    scope = user_scope_fixture()
    conversation = conversation_fixture(%{scope: scope})
    %{scope: scope, conversation_id: conversation.id}
  end

  defp row(scope, conversation_id, seq, message_type, content_type, text) do
    {:ok, row} =
      Conversations.append_display_message(scope, conversation_id, %{
        message_type: message_type,
        content_type: content_type,
        content: %{"text" => text},
        user_request_seq: seq
      })

    row
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        seq: 1,
        status: "completed",
        completed_at: DateTime.utc_now(),
        assistant_message_count: 2,
        tool_calls: %{"search" => 1},
        token_usage: %{"input" => 10, "output" => 2}
      },
      overrides
    )
  end

  describe "complete_user_request/4" do
    test "records the user request and marks only the given rows final", %{
      scope: scope,
      conversation_id: conversation_id
    } do
      _user = row(scope, conversation_id, 1, "user", "text", "question")
      work = row(scope, conversation_id, 1, "assistant", "text", "looking")
      answer = row(scope, conversation_id, 1, "assistant", "text", "answer")

      assert {:ok, %UserRequest{seq: 1, status: "completed"}} =
               Conversations.complete_user_request(scope, conversation_id, attrs(%{}), [answer.id])

      assert Repo.get!(DisplayMessage, answer.id).user_request_final
      refute Repo.get!(DisplayMessage, work.id).user_request_final
    end

    test "a second report upserts the row and moves the final flag", %{
      scope: scope,
      conversation_id: conversation_id
    } do
      first = row(scope, conversation_id, 1, "assistant", "text", "first")
      second = row(scope, conversation_id, 1, "assistant", "text", "second")

      {:ok, recorded} =
        Conversations.complete_user_request(
          scope,
          conversation_id,
          attrs(%{status: "error"}),
          [first.id]
        )

      recorded |> Ecto.Changeset.change(classification: "billable") |> Repo.update!()

      assert {:ok, _user_request} =
               Conversations.complete_user_request(scope, conversation_id, attrs(%{}), [second.id])

      assert [%UserRequest{status: "completed", classification: "billable"}] =
               Repo.all(UserRequest)

      refute Repo.get!(DisplayMessage, first.id).user_request_final
      assert Repo.get!(DisplayMessage, second.id).user_request_final
    end

    test "rejects a status sagents does not report", %{
      scope: scope,
      conversation_id: conversation_id
    } do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Conversations.complete_user_request(
                 scope,
                 conversation_id,
                 attrs(%{status: "finished"}),
                 []
               )

      assert %{status: ["is invalid"]} = errors_on(changeset)
      assert Repo.all(UserRequest) == []
    end

    test "rejects a conversation outside the scope", %{conversation_id: conversation_id} do
      assert {:error, :not_found} =
               Conversations.complete_user_request(
                 user_scope_fixture(),
                 conversation_id,
                 attrs(%{}),
                 []
               )
    end
  end

  describe "trailing_answer_row_ids/3" do
    test "returns the text rows after the user request's last non-answer row", %{
      scope: scope,
      conversation_id: conversation_id
    } do
      _user = row(scope, conversation_id, 2, "user", "text", "question")
      _early = row(scope, conversation_id, 2, "assistant", "text", "narration")

      {:ok, _tool} =
        Conversations.append_display_message(scope, conversation_id, %{
          message_type: "assistant",
          content_type: "tool_call",
          content: %{"call_id" => "call_1", "name" => "search", "arguments" => %{}},
          tool_call_id: "call_1",
          user_request_seq: 2
        })

      _thinking = row(scope, conversation_id, 2, "assistant", "thinking", "hmm")
      answer = row(scope, conversation_id, 2, "assistant", "text", "answer")

      assert Conversations.trailing_answer_row_ids(scope, conversation_id, 2) == [answer.id]
    end

    test "is empty for a user request with no rows", %{
      scope: scope,
      conversation_id: conversation_id
    } do
      assert Conversations.trailing_answer_row_ids(scope, conversation_id, 9) == []
    end
  end

  describe "user_requests_by_seq/2" do
    test "keys recorded user requests by seq", %{scope: scope, conversation_id: conversation_id} do
      {:ok, _user_request} =
        Conversations.complete_user_request(scope, conversation_id, attrs(%{seq: 1}), [])

      {:ok, _user_request} =
        Conversations.complete_user_request(scope, conversation_id, attrs(%{seq: 2}), [])

      assert %{1 => %UserRequest{seq: 1}, 2 => %UserRequest{seq: 2}} =
               Conversations.user_requests_by_seq(scope, conversation_id)
    end
  end
end

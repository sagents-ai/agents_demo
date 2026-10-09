defmodule AgentsDemoWeb.UserRequestGroupsTest do
  use ExUnit.Case, async: true

  alias AgentsDemoWeb.UserRequestGroups

  defp row(id, seq, message_type, opts \\ []) do
    %{
      id: id,
      user_request_seq: seq,
      message_type: message_type,
      content_type: Keyword.get(opts, :content_type, "text"),
      user_request_final: Keyword.get(opts, :final, false),
      inserted_at: Keyword.get(opts, :at, ~U[2026-10-07 12:00:00.000000Z])
    }
  end

  describe "build/2" do
    # Every group's runs, joined, are exactly its rows in display order.
    defp assert_order_kept(groups, rows) do
      for group <- groups do
        joined = Enum.map(group.opening_rows ++ group.work_rows ++ group.closing_rows, & &1.id)

        expected =
          rows
          |> Enum.filter(&(&1.user_request_seq == group.seq))
          |> Enum.map(& &1.id)

        if group.seq, do: assert(joined == expected)
      end

      groups
    end

    test "splits a group into opening, work, and closing runs" do
      rows = [
        row("u1", 1, "user"),
        row("w1", 1, "assistant", content_type: "tool_call"),
        row("f1", 1, "assistant", final: true),
        row("u2", 2, "user"),
        row("f2", 2, "assistant", final: true)
      ]

      user_request = %{seq: 1, status: "completed"}

      assert [
               %{
                 id: "user-request-1",
                 seq: 1,
                 opening_rows: [%{id: "u1"}],
                 work_rows: [%{id: "w1"}],
                 closing_rows: [%{id: "f1"}],
                 user_request: ^user_request
               },
               %{id: "user-request-2", seq: 2, user_request: nil, closing_rows: [%{id: "f2"}]}
             ] = rows |> UserRequestGroups.build(%{1 => user_request}) |> assert_order_kept(rows)
    end

    test "a user row added mid-request (an answer to a question) stays in place" do
      rows = [
        row("u1", 1, "user"),
        row("q1", 1, "assistant", content_type: "tool_call"),
        row("a1", 1, "user"),
        row("n1", 1, "system", content_type: "notification"),
        row("f1", 1, "assistant", final: true)
      ]

      assert [
               %{
                 opening_rows: [%{id: "u1"}],
                 work_rows: [%{id: "q1"}, %{id: "a1"}, %{id: "n1"}],
                 closing_rows: [%{id: "f1"}]
               }
             ] = rows |> UserRequestGroups.build(%{}) |> assert_order_kept(rows)
    end

    test "rows after the final answer stay after it" do
      rows = [
        row("u1", 1, "user"),
        row("f1", 1, "assistant", final: true),
        row("s1", 1, "assistant", content_type: "todo_snapshot"),
        row("x1", 1, "user")
      ]

      assert [
               %{
                 opening_rows: [%{id: "u1"}],
                 work_rows: [],
                 closing_rows: [%{id: "f1"}, %{id: "s1"}, %{id: "x1"}]
               }
             ] = rows |> UserRequestGroups.build(%{}) |> assert_order_kept(rows)
    end

    test "without a final answer everything after the opening is work" do
      rows = [
        row("u1", 1, "user"),
        row("w1", 1, "assistant"),
        row("w2", 1, "assistant", content_type: "error")
      ]

      assert [
               %{
                 opening_rows: [%{id: "u1"}],
                 work_rows: [%{id: "w1"}, %{id: "w2"}],
                 closing_rows: []
               }
             ] =
               rows |> UserRequestGroups.build(%{}) |> assert_order_kept(rows)
    end

    test "two user messages that opened the request together are both the opening" do
      rows = [row("u1", 1, "user"), row("u2", 1, "user"), row("w1", 1, "assistant")]

      assert [%{opening_rows: [%{id: "u1"}, %{id: "u2"}], work_rows: [%{id: "w1"}]}] =
               UserRequestGroups.build(rows, %{})
    end

    test "rows without a number each form a group of their own" do
      rows = [row("a", nil, "user"), row("b", nil, "assistant")]

      assert [
               %{id: "row-0", seq: nil, work_rows: [%{id: "a"}]},
               %{id: "row-1", seq: nil, work_rows: [%{id: "b"}]}
             ] = UserRequestGroups.build(rows, %{})
    end

    test "a row's number alone decides its group" do
      # The second request was typed while the first was still working, so
      # its row sits among the first request's rows.
      rows = [
        row("u1", 1, "user"),
        row("w1", 1, "assistant", content_type: "tool_call"),
        row("u2", 2, "user"),
        row("f1", 1, "assistant", final: true),
        row("f2", 2, "assistant", final: true)
      ]

      assert [
               %{
                 seq: 1,
                 opening_rows: [%{id: "u1"}],
                 work_rows: [%{id: "w1"}],
                 closing_rows: [%{id: "f1"}]
               },
               %{seq: 2, opening_rows: [%{id: "u2"}], work_rows: [], closing_rows: [%{id: "f2"}]}
             ] = rows |> UserRequestGroups.build(%{}) |> assert_order_kept(rows)
    end

    test "the group starts at its first row" do
      rows = [
        row("u1", 1, "user", at: ~U[2026-10-07 12:00:00.000000Z]),
        row("f1", 1, "assistant", at: ~U[2026-10-07 12:00:30.000000Z])
      ]

      assert [%{started_at: ~U[2026-10-07 12:00:00.000000Z]}] = UserRequestGroups.build(rows, %{})
    end
  end

  describe "duration_label/2" do
    test "formats seconds, minutes, and hours" do
      start = ~U[2026-10-07 12:00:00Z]

      assert UserRequestGroups.duration_label(start, DateTime.add(start, 45)) == "45s"
      assert UserRequestGroups.duration_label(start, DateTime.add(start, 59)) == "59s"
      assert UserRequestGroups.duration_label(start, DateTime.add(start, 60)) == "1m 0s"
      assert UserRequestGroups.duration_label(start, DateTime.add(start, 134)) == "2m 14s"
      assert UserRequestGroups.duration_label(start, DateTime.add(start, 3600)) == "1h 0m"
      assert UserRequestGroups.duration_label(start, DateTime.add(start, 3780)) == "1h 3m"
    end

    test "never goes negative" do
      start = ~U[2026-10-07 12:00:00Z]
      assert UserRequestGroups.duration_label(start, DateTime.add(start, -5)) == "0s"
    end
  end
end

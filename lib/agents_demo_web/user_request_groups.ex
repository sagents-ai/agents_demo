defmodule AgentsDemoWeb.UserRequestGroups do
  @moduledoc """
  Groups a conversation's display rows by user request for rendering.

  Each group is one user request. A row's user request number alone decides
  its group, and a group's rows keep their display order. They are split into
  three consecutive runs that together are exactly the group's rows:

    * `opening_rows` - the leading user rows: the message that opened it
    * `work_rows` - everything after, up to the first final-answer row,
      including any user row added along the way (an answer to a question,
      an approval, a synthetic row)
    * `closing_rows` - the first final-answer row and everything after it

  A UI folds `work_rows` away once the user request is complete; nothing moves.
  Rows without a user request number (older conversations) each form a group
  of their own and render as before.

  A group's position is its first row's. A user message typed while the agent
  was busy is saved during the previous user request, so its group can begin
  before the previous group's last row. Grouping by number keeps each
  user request's rows together regardless.
  """

  @type group :: %{
          id: String.t(),
          seq: pos_integer() | nil,
          opening_rows: list(),
          work_rows: list(),
          closing_rows: list(),
          user_request: map() | nil,
          started_at: DateTime.t() | nil
        }

  @doc """
  Build render groups from rows in display order and recorded user requests
  keyed by `seq`. Groups are ordered by their first row.
  """
  @spec build(list(), %{pos_integer() => map()}) :: [group()]
  def build(rows, user_requests_by_seq) do
    rows
    |> Enum.with_index()
    |> Enum.group_by(fn {row, index} -> group_key(row, index) end)
    |> Enum.map(fn {key, indexed} ->
      {first_index(indexed),
       build_group(key, Enum.map(indexed, &elem(&1, 0)), user_requests_by_seq)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp group_key(row, index) do
    case Map.get(row, :user_request_seq) do
      seq when is_integer(seq) -> seq
      _none -> {:ungrouped, index}
    end
  end

  defp first_index([{_row, index} | _rest]), do: index

  defp build_group({:ungrouped, index}, rows, _user_requests) do
    %{
      id: "row-#{index}",
      seq: nil,
      opening_rows: [],
      work_rows: rows,
      closing_rows: [],
      user_request: nil,
      started_at: nil
    }
  end

  defp build_group(seq, rows, user_requests) do
    {opening_rows, rest} = Enum.split_while(rows, &(&1.message_type == "user"))

    {work_rows, closing_rows} =
      Enum.split_while(rest, &(not Map.get(&1, :user_request_final, false)))

    %{
      id: "user-request-#{seq}",
      seq: seq,
      opening_rows: opening_rows,
      work_rows: work_rows,
      closing_rows: closing_rows,
      user_request: Map.get(user_requests, seq),
      started_at: rows |> List.first() |> Map.get(:inserted_at)
    }
  end

  @doc """
  Format how long a user request ran, as "45s", "2m 14s" or "1h 3m".
  """
  @spec duration_label(DateTime.t(), DateTime.t()) :: String.t()
  def duration_label(%DateTime{} = started_at, %DateTime{} = completed_at) do
    seconds = max(DateTime.diff(completed_at, started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end
end

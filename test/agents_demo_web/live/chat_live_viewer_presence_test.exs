defmodule AgentsDemoWeb.ChatLiveViewerPresenceTest do
  @moduledoc """
  A LiveView process outlives the conversation it is showing, so `Phoenix.Presence`
  reaping the entry on process exit is a backstop rather than the mechanism.
  These drive the switch itself and read what Presence actually holds.

  A viewer left behind on a conversation the user walked away from is what stops
  `Sagents.AgentServer` from releasing that conversation's idle agent, so it
  waits out the full inactivity timeout instead.
  """
  use AgentsDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures

  alias AgentsDemo.Agents.AgentSubscriberSession
  alias AgentsDemo.Agents.Coordinator
  alias AgentsDemo.Conversations

  setup do
    user = user_fixture()
    scope = %AgentsDemo.Accounts.Scope{user: user}

    {:ok, first} = Conversations.create_conversation(scope, %{title: "First"})
    {:ok, second} = Conversations.create_conversation(scope, %{title: "Second"})

    %{
      user: user,
      conn: log_in_user(build_conn(), user),
      first: first,
      second: second
    }
  end

  # Presence keys are strings, whatever the viewer id was tracked as.
  defp viewers(conversation_id), do: Coordinator.list_conversation_viewers(conversation_id)

  test "switching conversations moves the viewer instead of leaving one behind",
       %{conn: conn, user: user, first: first, second: second} do
    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{first.id}")

    assert Map.has_key?(viewers(first.id), to_string(user.id))
    assert viewers(second.id) == %{}

    render_patch(view, ~p"/chat?conversation_id=#{second.id}")

    assert viewers(first.id) == %{},
           "the first conversation still has a viewer after switching away from it"

    assert Map.has_key?(viewers(second.id), to_string(user.id))
  end

  test "opening several conversations in one session holds exactly one entry",
       %{conn: conn, user: user, first: first, second: second} do
    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{first.id}")

    for _round <- 1..3 do
      render_patch(view, ~p"/chat?conversation_id=#{second.id}")
      render_patch(view, ~p"/chat?conversation_id=#{first.id}")
    end

    assert Map.has_key?(viewers(first.id), to_string(user.id))
    assert viewers(second.id) == %{}
  end

  describe "several conversations viewed from one process" do
    # What the generated ChatLive does not do, but the session module supports:
    # a split view, a dashboard row per running agent, a panel of note threads
    # each backed by its own forked agent. Presence entries are per topic, so
    # one process holds one per conversation.
    setup %{user: user} do
      scope = %AgentsDemo.Accounts.Scope{user: user}

      conversations =
        for n <- 1..7 do
          {:ok, conversation} = Conversations.create_conversation(scope, %{title: "Note #{n}"})
          conversation
        end

      %{conversations: conversations}
    end

    test "one process holds an entry per conversation", %{user: user, conversations: convs} do
      desired = Map.new(convs, &{&1.id, user.id})

      %{tracked_viewers: held} =
        AgentSubscriberSession.sync_tracked_viewers(%{tracked_viewers: %{}}, desired)

      assert map_size(held) == 7

      for conversation <- convs do
        assert Map.has_key?(viewers(conversation.id), to_string(user.id)),
               "conversation #{conversation.id} is not being viewed"
      end

      # Closing one panel leaves the other six being viewed.
      [closed | still_open] = convs

      %{tracked_viewers: held} =
        AgentSubscriberSession.remove_tracked_viewer(%{tracked_viewers: held}, closed.id)

      assert map_size(held) == 6
      assert viewers(closed.id) == %{}

      for conversation <- still_open do
        assert Map.has_key?(viewers(conversation.id), to_string(user.id))
      end

      AgentSubscriberSession.clear_tracked_viewers(%{tracked_viewers: held})
    end

    test "re-declaring the viewed set disturbs nothing that stays",
         %{user: user, conversations: convs} do
      # Idempotence is the point, not tidiness. An untrack followed by a track
      # of the same conversation is a leave broadcast, and an idle agent that
      # acts on it schedules the shutdown the entry exists to prevent.
      [a, b, c | _rest] = convs

      %{tracked_viewers: held} =
        AgentSubscriberSession.sync_tracked_viewers(
          %{tracked_viewers: %{}},
          %{a.id => user.id, b.id => user.id}
        )

      %{tracked_viewers: held} =
        AgentSubscriberSession.sync_tracked_viewers(
          %{tracked_viewers: held},
          %{b.id => user.id, c.id => user.id}
        )

      assert viewers(a.id) == %{}
      assert Map.has_key?(viewers(b.id), to_string(user.id))
      assert Map.has_key?(viewers(c.id), to_string(user.id))

      %{tracked_viewers: held} =
        AgentSubscriberSession.clear_tracked_viewers(%{tracked_viewers: held})

      assert held == %{}
      assert viewers(b.id) == %{}
      assert viewers(c.id) == %{}
    end
  end

  test "starting a new thread releases the viewer entry",
       %{conn: conn, first: first} do
    {:ok, view, _html} = live(conn, ~p"/chat?conversation_id=#{first.id}")

    assert map_size(viewers(first.id)) == 1

    view |> element("button[phx-click='new_thread']") |> render_click()

    assert viewers(first.id) == %{},
           "the conversation the user left still has a viewer"
  end
end

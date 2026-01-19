defmodule AgentsDemoWeb.ChatLiveAgentStartupTest do
  @moduledoc """
  Integration test for reproducing agent startup timeout issues when creating
  multiple conversations in succession.

  This test specifically targets the bug where:
  1. First conversation starts successfully
  2. User clicks "New Thread"
  3. User quickly creates a new conversation
  4. New agent fails to start with 5-second timeout
  5. LiveView crashes with FunctionClauseError on nil agent_id
  """
  use AgentsDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures

  alias Sagents.AgentServer

  require Logger

  @moduletag :integration

  setup do
    user = user_fixture()
    %{user: user, conn: log_in_user(build_conn(), user)}
  end

  defp submit_message(view, message) do
    # Wait for input to be enabled (agent_status != :running)
    # Poll up to 1 second
    Enum.reduce_while(1..10, nil, fn _attempt, _acc ->
      socket_assigns = :sys.get_state(view.pid).socket.assigns

      if socket_assigns[:agent_status] in [:idle, :cancelled, :error, nil] do
        {:halt, :ok}
      else
        Process.sleep(100)
        {:cont, nil}
      end
    end)

    # Fill in the input field
    view
    |> element("input[name='message']")
    |> render_change(%{message: message})

    # Submit the form
    view
    |> element("form[phx-submit='send_message']")
    |> render_submit(%{message: message})
  end

  describe "sequential conversation creation" do
    @tag live_call: true
    test "creates second conversation after clicking new thread", %{conn: conn} do
      # Start first conversation
      {:ok, view, _html} = live(conn, ~p"/chat")

      submit_message(view, "First conversation")

      Process.sleep(100)
      first_conversation_id = extract_conversation_id(view)
      first_agent_id = "conversation-#{first_conversation_id}"

      # Verify first agent is running
      assert AgentServer.get_pid(first_agent_id) != nil
      Logger.info("First agent #{first_agent_id} running")

      # Click "New Thread" button
      view
      |> element("button[phx-click='new_thread']")
      |> render_click()

      # Verify conversation_id was cleared
      assert extract_conversation_id(view) == nil, "Conversation should be cleared after new thread"
      Logger.info("Clicked 'New Thread', conversation cleared")

      # Wait a moment to simulate user delay
      Process.sleep(50)

      # Submit second message to create second conversation
      Logger.info("Submitting message for second conversation...")

      submit_message(view, "Second conversation")

      # Wait for agent startup (may timeout)
      Process.sleep(6000)

      # Check if second conversation was created
      second_conversation_id = extract_conversation_id(view)

      if second_conversation_id do
        Logger.info("Second conversation created: #{second_conversation_id}")

        # Check if agent started
        second_agent_id = "conversation-#{second_conversation_id}"

        case AgentServer.get_pid(second_agent_id) do
          nil ->
            Logger.error("BUG REPRODUCED: Second agent #{second_agent_id} failed to start")
            flunk("Second agent failed to start within timeout")

          pid ->
            Logger.info("Second agent #{second_agent_id} started successfully at #{inspect(pid)}")
            assert true
        end
      else
        Logger.error("BUG REPRODUCED: Second conversation was not created")
        flunk("Second conversation was not created")
      end

      # Verify first agent is still running (or timed out naturally)
      case AgentServer.get_pid(first_agent_id) do
        nil ->
          Logger.info("First agent #{first_agent_id} has stopped (expected if inactive)")

        pid ->
          Logger.info("First agent #{first_agent_id} still running at #{inspect(pid)}")
      end
    end
  end

  # Helper functions

  defp extract_conversation_id(view) do
    # Try to extract from assigns
    socket_assigns = :sys.get_state(view.pid).socket.assigns

    socket_assigns[:conversation_id]
  end
end

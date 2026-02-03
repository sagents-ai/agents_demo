defmodule AgentsDemoWeb.ChatLiveTodosTest do
  @moduledoc """
  Integration test for TODOs functionality in ChatLive with mocked LLM responses.

  This test verifies the complete flow:
  1. User sends a message to the agent
  2. Agent responds with write_todos tool call
  3. TODOs appear in the LiveView assigns and UI
  4. Conversation title is generated
  5. Agent sends final response

  ## Current Status

  **NOTE**: This test currently FAILS and reproduces the TODO broadcasting bug.
  The agent successfully executes the write_todos tool, but TODOs don't appear
  in the LiveView assigns (expected: 6, actual: 0).

  Root cause: The `clear_if_all_completed()` function in TodoList middleware
  clears completed TODOs, and the broadcast comparison fails to detect changes
  when going from empty [] to empty [].

  See: TEST_TODOS_DEBUG.md for fix recommendations.

  This test will PASS once the broadcasting logic is fixed.
  """
  use AgentsDemoWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest
  import AgentsDemo.AccountsFixtures

  alias Sagents.AgentServer
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias LangChain.Message.ToolCall

  require Logger

  # Need to set Mimic to global mode because the agent executes in a separate Task
  setup :set_mimic_global

  setup do
    # Set dummy API key for tests
    System.put_env("ANTHROPIC_API_KEY", "test_api_key_12345")

    user = user_fixture()
    %{user: user, conn: log_in_user(build_conn(), user)}
  end

  defp wait_for_agent_status(view, expected_status, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      socket_assigns = :sys.get_state(view.pid).socket.assigns
      current_status = socket_assigns[:agent_status]

      if current_status == expected_status do
        {:ok, socket_assigns}
      else
        if System.monotonic_time(:millisecond) > deadline do
          {:timeout, current_status}
        else
          Process.sleep(50)
          :continue
        end
      end
    end)
    |> Enum.find(&(&1 != :continue))
  end

  defp submit_message(view, message) do
    # Wait for input to be enabled (agent not running)
    case wait_for_agent_status(view, :idle, 2000) do
      {:ok, _assigns} -> :ok
      {:timeout, status} -> Logger.warning("Timed out waiting for idle, got: #{inspect(status)}")
    end

    # Fill in the input field
    view
    |> element("input[name='message']")
    |> render_change(%{message: message})

    # Submit the form
    view
    |> element("form[phx-submit='send_message']")
    |> render_submit(%{message: message})
  end

  describe "TODOs integration with mocked LLM" do
    test "displays TODOs when agent uses write_todos tool", %{conn: conn} do
      # Navigate to chat page
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Mock the three LLM responses we expect:
      # 1. Agent response with write_todos tool call
      # 2. Title generation
      # 3. Final "I did it!" response

      expect(ChatAnthropic, :call, 3, fn _model, messages, _tools ->
        last_message = List.last(messages)

        cond do
          # First call: Agent makes write_todos tool call
          match?(%Message{role: :user}, last_message) and
              Enum.any?(messages, fn msg ->
                match?(%Message{role: :user}, msg) and
                    Enum.any?(msg.content, fn part ->
                      String.contains?(part.content, "Create a project plan")
                    end)
              end) ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_write_todos_123",
                name: "write_todos",
                arguments: %{
                  "merge" => false,
                  "todos" => [
                    %{
                      "content" => "Research project requirements and gather specifications",
                      "id" => "1",
                      "status" => "completed"
                    },
                    %{
                      "content" => "Design database schema and API endpoints",
                      "id" => "2",
                      "status" => "in_progress"
                    },
                    %{
                      "content" => "Implement user authentication system",
                      "id" => "3",
                      "status" => "pending"
                    },
                    %{
                      "content" => "Write unit tests for core functionality",
                      "id" => "4",
                      "status" => "pending"
                    },
                    %{
                      "content" => "Create documentation and user guide",
                      "id" => "5",
                      "status" => "pending"
                    },
                    %{
                      "content" => "Deploy to staging environment for testing",
                      "id" => "6",
                      "status" => "pending"
                    }
                  ]
                }
              })

            {:ok,
             [
               Message.new_assistant!(%{
                 content: "I'll create a project plan with tasks.",
                 tool_calls: [tool_call]
               })
             ]}

          # Second call: Title generation (system prompt + messages for title)
          # This is called by ConversationTitle middleware
          Enum.any?(messages, fn msg ->
            match?(%Message{role: :system}, msg) and
                String.contains?(List.first(msg.content || []) |> Map.get(:content, ""), "title")
          end) ->
            {:ok, [Message.new_assistant!("Project Planning Discussion")]}

          # Third call: Final response after tool execution
          Enum.any?(messages, fn msg ->
            match?(%Message{role: :tool}, msg) and
              msg.tool_results != nil and
                Enum.any?(msg.tool_results, fn result ->
                  result.name == "write_todos"
                end)
          end) ->
            {:ok, [Message.new_assistant!("I did it!")]}

          # Fallback for unexpected calls
          true ->
            Logger.warning("Unexpected LLM call with messages: #{inspect(messages)}")
            {:ok, [Message.new_assistant!("Unexpected response")]}
        end
      end)

      # Send the message that triggers the agent
      submit_message(view, "Create a project plan")

      # Wait for agent to complete execution
      case wait_for_agent_status(view, :idle, 10_000) do
        {:ok, assigns} ->
          # Verify TODOs are present in assigns
          todos = assigns[:todos]
          assert is_list(todos), "Expected todos to be a list, got: #{inspect(todos)}"
          assert length(todos) == 6, "Expected 6 todos, got: #{length(todos)}"

          # Verify TODO content
          [todo1, todo2, todo3, todo4, todo5, todo6] = todos

          assert todo1.content == "Research project requirements and gather specifications"
          assert todo1.status == :completed

          assert todo2.content == "Design database schema and API endpoints"
          assert todo2.status == :in_progress

          assert todo3.content == "Implement user authentication system"
          assert todo3.status == :pending

          assert todo4.content == "Write unit tests for core functionality"
          assert todo4.status == :pending

          assert todo5.content == "Create documentation and user guide"
          assert todo5.status == :pending

          assert todo6.content == "Deploy to staging environment for testing"
          assert todo6.status == :pending

          # Verify TODOs appear in rendered HTML
          html = render(view)
          assert html =~ "Research project requirements"
          assert html =~ "Design database schema"
          assert html =~ "data-status=\"in_progress\""
          assert html =~ "data-status=\"completed\""
          assert html =~ "data-status=\"pending\""

          # Verify conversation was created and title was updated
          conversation_id = assigns[:conversation_id]
          assert conversation_id != nil

          # Give title generation a moment to complete (it runs async)
          Process.sleep(200)

          # Verify final message appears
          assert html =~ "I did it!"

        {:timeout, status} ->
          flunk("Agent did not complete execution. Status: #{inspect(status)}")
      end
    end

    test "TODOs persist across page reloads", %{conn: conn} do
      # Navigate to chat page
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Mock LLM responses
      expect(ChatAnthropic, :call, 3, fn _model, messages, _tools ->
        last_message = List.last(messages)

        cond do
          # First call: write_todos tool call
          match?(%Message{role: :user}, last_message) ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_todos_456",
                name: "write_todos",
                arguments: %{
                  "merge" => false,
                  "todos" => [
                    %{"content" => "Task 1", "id" => "1", "status" => "pending"},
                    %{"content" => "Task 2", "id" => "2", "status" => "in_progress"}
                  ]
                }
              })

            {:ok, [Message.new_assistant!(%{content: "Creating tasks", tool_calls: [tool_call]})]}

          # Title generation
          Enum.any?(messages, fn msg ->
            match?(%Message{role: :system}, msg)
          end) ->
            {:ok, [Message.new_assistant!("Task Management")]}

          # Final response
          true ->
            {:ok, [Message.new_assistant!("Tasks created!")]}
        end
      end)

      # Send message to create TODOs
      submit_message(view, "Create two tasks")

      # Wait for agent completion
      {:ok, assigns} = wait_for_agent_status(view, :idle, 10_000)

      # Verify TODOs are present
      assert length(assigns[:todos]) == 2

      # Get conversation_id for reload
      conversation_id = assigns[:conversation_id]
      assert conversation_id != nil

      # Reload the page
      {:ok, new_view, _html} = live(conn, ~p"/chat?conversation_id=#{conversation_id}")

      # Wait for page to load
      Process.sleep(100)

      # Verify TODOs are still present after reload
      reloaded_assigns = :sys.get_state(new_view.pid).socket.assigns
      _reloaded_todos = reloaded_assigns[:todos]

      # Note: TODOs come from agent state, not from database
      # If agent is not running, TODOs will be empty until agent starts
      # This is expected behavior - TODOs are runtime state

      # To properly test this, we need to ensure the agent has started
      # The Coordinator starts the agent on-demand when loading conversation

      # Give agent time to start and load state
      Process.sleep(500)

      # Get updated assigns after agent startup
      final_assigns = :sys.get_state(new_view.pid).socket.assigns
      final_todos = final_assigns[:todos]

      # If agent hasn't broadcast state yet, subscribe and wait
      if Enum.empty?(final_todos || []) do
        agent_id = final_assigns[:agent_id]

        if agent_id do
          AgentServer.subscribe(agent_id)

          # Wait for todos_updated event
          receive do
            {:todos_updated, todos} ->
              assert length(todos) == 2
              assert Enum.any?(todos, &(&1.content == "Task 1"))
              assert Enum.any?(todos, &(&1.content == "Task 2"))
          after
            2000 ->
              flunk("Did not receive todos_updated event after page reload")
          end
        else
          flunk("Agent ID not set after conversation reload")
        end
      else
        # TODOs were present immediately
        assert length(final_todos) == 2
      end
    end

    test "multiple TODO updates are reflected in UI", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # First message: Create initial TODOs
      expect(ChatAnthropic, :call, 3, fn _model, messages, _tools ->
        last_message = List.last(messages)

        cond do
          # First tool call
          match?(%Message{role: :user}, last_message) and
              Enum.any?(messages, fn msg ->
                match?(%Message{role: :user}, msg) and
                    Enum.any?(msg.content, fn part ->
                      String.contains?(part.content, "Create initial tasks")
                    end)
              end) ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_initial",
                name: "write_todos",
                arguments: %{
                  "merge" => false,
                  "todos" => [
                    %{"content" => "Initial Task 1", "id" => "1", "status" => "pending"},
                    %{"content" => "Initial Task 2", "id" => "2", "status" => "pending"}
                  ]
                }
              })

            {:ok, [Message.new_assistant!(%{content: "Creating", tool_calls: [tool_call]})]}

          # Title generation
          Enum.any?(messages, fn msg -> match?(%Message{role: :system}, msg) end) ->
            {:ok, [Message.new_assistant!("Task Management")]}

          # Final response
          true ->
            {:ok, [Message.new_assistant!("Initial tasks created")]}
        end
      end)

      submit_message(view, "Create initial tasks")
      {:ok, assigns} = wait_for_agent_status(view, :idle, 10_000)
      assert length(assigns[:todos]) == 2

      # Second message: Update TODOs
      expect(ChatAnthropic, :call, 2, fn _model, messages, _tools ->
        last_message = List.last(messages)

        cond do
          # Update tool call
          match?(%Message{role: :user}, last_message) and
              Enum.any?(messages, fn msg ->
                match?(%Message{role: :user}, msg) and
                    Enum.any?(msg.content, fn part ->
                      String.contains?(part.content, "Mark first task complete")
                    end)
              end) ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_update",
                name: "write_todos",
                arguments: %{
                  "merge" => true,
                  "todos" => [
                    %{"content" => "Initial Task 1", "id" => "1", "status" => "completed"}
                  ]
                }
              })

            {:ok, [Message.new_assistant!(%{content: "Updating", tool_calls: [tool_call]})]}

          # Final response
          true ->
            {:ok, [Message.new_assistant!("Task updated!")]}
        end
      end)

      submit_message(view, "Mark first task complete")
      {:ok, updated_assigns} = wait_for_agent_status(view, :idle, 10_000)

      # Verify first task is now completed
      todos = updated_assigns[:todos]
      assert length(todos) == 2

      task1 = Enum.find(todos, &(&1.id == "1"))
      assert task1.status == :completed

      task2 = Enum.find(todos, &(&1.id == "2"))
      assert task2.status == :pending
    end
  end

  describe "TODOs error handling" do
    test "handles agent errors gracefully without breaking TODO display", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # First: successful TODO creation
      expect(ChatAnthropic, :call, 3, fn _model, messages, _tools ->
        last_message = List.last(messages)

        cond do
          match?(%Message{role: :user}, last_message) ->
            tool_call =
              ToolCall.new!(%{
                call_id: "call_success",
                name: "write_todos",
                arguments: %{
                  "merge" => false,
                  "todos" => [%{"content" => "Task 1", "id" => "1", "status" => "pending"}]
                }
              })

            {:ok, [Message.new_assistant!(%{content: "Creating", tool_calls: [tool_call]})]}

          Enum.any?(messages, fn msg -> match?(%Message{role: :system}, msg) end) ->
            {:ok, [Message.new_assistant!("Title")]}

          true ->
            {:ok, [Message.new_assistant!("Done")]}
        end
      end)

      submit_message(view, "Create a task")
      {:ok, assigns} = wait_for_agent_status(view, :idle, 10_000)
      assert length(assigns[:todos]) == 1

      # Second: simulate LLM error
      expect(ChatAnthropic, :call, 1, fn _model, _messages, _tools ->
        {:error, "API timeout"}
      end)

      submit_message(view, "This will fail")

      # Wait for error state
      case wait_for_agent_status(view, :error, 5_000) do
        {:ok, error_assigns} ->
          # Verify TODOs are still present despite the error
          assert length(error_assigns[:todos]) == 1

        {:timeout, status} ->
          flunk("Expected agent to enter error state, got: #{inspect(status)}")
      end
    end
  end
end

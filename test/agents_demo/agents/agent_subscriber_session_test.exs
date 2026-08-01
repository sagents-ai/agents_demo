defmodule AgentsDemo.Agents.AgentSubscriberSessionTest do
  use ExUnit.Case, async: true

  alias AgentsDemo.Agents.AgentSubscriberSession

  describe "init_session_state/0" do
    test "starts with agent_status :not_running so the Wake button is shown for empty state" do
      state = AgentSubscriberSession.init_session_state()
      assert state.agent_status == :not_running
      assert state.agent_id == nil
    end
  end

  describe "handle_agent_shutdown/2" do
    defp shutdown(overrides \\ %{}) do
      Map.merge(
        %{
          agent_id: "conversation-1",
          reason: :inactivity,
          status: :idle,
          interrupt_restorable: false,
          last_activity_at: nil,
          shutdown_at: DateTime.utc_now()
        },
        overrides
      )
    end

    defp interrupted_state do
      %{
        agent_id: "conversation-1",
        agent_status: :interrupted,
        agent_alive?: true,
        loading: false,
        streaming_delta: nil,
        interrupt_data: %{type: :ask_user_question, tool_call_id: "call-1"},
        pending_question: %{tool_call_id: "call-1", question: "Which one?"},
        remaining_questions: [],
        question_responses: [],
        pending_tools: [],
        pending_halt: nil,
        sagents_subs: %{}
      }
    end

    test "flips agent_status to :not_running so the Wake button reappears" do
      state = %{
        agent_id: "conversation-1",
        agent_status: :idle,
        loading: true,
        streaming_delta: %{},
        sagents_subs: %{}
      }

      changes = AgentSubscriberSession.handle_agent_shutdown(state, shutdown())

      assert changes.agent_status == :not_running
      assert changes.agent_alive? == false
      assert changes.loading == false
      assert changes.streaming_delta == nil
    end

    test "never clears agent_id: it is a pure function of the conversation id" do
      state = %{
        agent_id: "conversation-1",
        agent_status: :idle,
        loading: false,
        sagents_subs: %{}
      }

      changes = AgentSubscriberSession.handle_agent_shutdown(state, shutdown())

      refute Map.has_key?(changes, :agent_id)
    end

    test "never touches the subs map, so presence-driven re-subscribe still works" do
      state = %{
        agent_id: "conversation-1",
        agent_status: :idle,
        sagents_subs: %{{:agent, "conversation-1"} => %{state: :subscribed}}
      }

      changes = AgentSubscriberSession.handle_agent_shutdown(state, shutdown())

      refute Map.has_key?(changes, :sagents_subs)
    end

    test "keeps a restorable question on screen, only marking the agent not alive" do
      changes =
        AgentSubscriberSession.handle_agent_shutdown(
          interrupted_state(),
          shutdown(%{status: :interrupted, interrupt_restorable: true})
        )

      assert changes == %{agent_alive?: false, loading: false, streaming_delta: nil}
      refute Map.has_key?(changes, :agent_status)
      refute Map.has_key?(changes, :pending_question)
    end

    test "clears a non-restorable interrupt (e.g. a sub-agent approval)" do
      state = %{
        interrupted_state()
        | pending_question: nil,
          pending_tools: [%{tool_call_id: "call-1", tool_name: "write_file"}],
          interrupt_data: %{type: :subagent_hitl}
      }

      changes =
        AgentSubscriberSession.handle_agent_shutdown(
          state,
          shutdown(%{status: :interrupted, interrupt_restorable: false})
        )

      assert changes.agent_status == :not_running
      assert changes.pending_tools == []
      assert changes.interrupt_data == nil
    end

    test "treats a missing :interrupt_restorable flag as not restorable" do
      changes =
        AgentSubscriberSession.handle_agent_shutdown(
          interrupted_state(),
          %{agent_id: "conversation-1", reason: :inactivity, status: :interrupted}
        )

      assert changes.agent_status == :not_running
      assert changes.pending_question == nil
    end

    test "is idempotent across the repeated deliveries a single shutdown sends" do
      payload = shutdown(%{status: :interrupted, interrupt_restorable: true})

      first = AgentSubscriberSession.handle_agent_shutdown(interrupted_state(), payload)
      after_first = Map.merge(interrupted_state(), first)
      second = AgentSubscriberSession.handle_agent_shutdown(after_first, payload)

      assert first == second
      assert Map.merge(after_first, second) == after_first
    end

    test "keeps a half-answered question batch intact so it can finish after the wake" do
      state = %{
        interrupted_state()
        | pending_question: %{tool_call_id: "call-2", question: "And the second?"},
          remaining_questions: [%{tool_call_id: "call-3", question: "And the third?"}],
          question_responses: [%{tool_call_id: "call-1", type: :answer}],
          interrupt_data: %{type: :multiple_interrupts, interrupts: []}
      }

      changes =
        AgentSubscriberSession.handle_agent_shutdown(
          state,
          shutdown(%{status: :interrupted, interrupt_restorable: true})
        )

      merged = Map.merge(state, changes)

      assert merged.question_responses == [%{tool_call_id: "call-1", type: :answer}]
      assert merged.remaining_questions == [%{tool_call_id: "call-3", question: "And the third?"}]
      assert merged.agent_status == :interrupted
    end
  end

  describe "agent_alive? vocabulary" do
    test "every status handler reports the agent as alive" do
      assert AgentSubscriberSession.handle_status_running().agent_alive?
      assert AgentSubscriberSession.handle_status_idle().agent_alive?
      assert AgentSubscriberSession.handle_status_cancelled().agent_alive?
      assert AgentSubscriberSession.handle_status_error(:boom).agent_alive?

      assert AgentSubscriberSession.handle_status_interrupted(%{type: :ask_user_question}).agent_alive?
    end

    test "a producer DOWN reports the agent as not alive without touching interrupt state" do
      ref = make_ref()

      state = %{
        sagents_subs: %{
          {:agent, "conversation-1"} => %{
            channel: :main,
            server_pid: self(),
            monitor_ref: nil,
            client_ref: ref,
            state: :subscribed
          }
        }
      }

      changes = AgentSubscriberSession.handle_publisher_down(state, ref, :shutdown)

      assert changes.agent_alive? == false
      assert changes.sagents_subs[{:agent, "conversation-1"}].state == :pending
      refute Map.has_key?(changes, :agent_status)
      refute Map.has_key?(changes, :pending_question)
    end
  end
end

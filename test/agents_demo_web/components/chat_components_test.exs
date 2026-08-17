defmodule AgentsDemoWeb.ChatComponentsTest do
  # Pure function-component renders - no DB sandbox needed, so this does not
  # use ConnCase (which also doesn't import Phoenix.LiveViewTest).
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AgentsDemoWeb.ChatComponents
  alias LangChain.Message.ContentPart
  alias LangChain.MessageDelta

  # Text ending on a lone `~` used as an "approximately" shorthand. In MDEx's
  # streaming mode this trailing delimiter is read as an *opening* strikethrough
  # whose closer hasn't streamed in yet.
  @trailing_tilde "5. **Style Guide** (~1,486 words)"

  @json_fence """
  ```json
  {"name": "search", "limit": 10}
  ```
  """

  describe "markdown/1" do
    defp render_md(assigns) do
      render_component(&ChatComponents.markdown/1, assigns)
    end

    test "completed (non-streaming) content keeps a trailing unpaired tilde literal" do
      # Regression: a fully-received assistant message must NOT have its trailing
      # text struck through. See the streaming-mode note on markdown/1.
      html = render_md(%{text: @trailing_tilde})

      assert html =~ "~1,486"
      refute html =~ "<del>"
    end

    test "streaming content treats a trailing unpaired tilde as an open strikethrough" do
      # Streaming mode is intentionally optimistic: the buffer may be truncated
      # mid-token, so a lone trailing `~` opens a `<del>` that self-corrects once
      # the closing delimiter arrives. Pins that streaming mode is really active.
      html = render_md(%{text: @trailing_tilde, streaming: true})

      assert html =~ "<del>"
    end

    test "properly paired strikethrough renders in both modes" do
      # Guards against accidentally disabling the strikethrough extension.
      assert render_md(%{text: "this is ~~struck~~ text"}) =~ "<del>struck</del>"

      assert render_md(%{text: "this is ~~struck~~ text", streaming: true}) =~
               "<del>struck</del>"
    end

    test "a fenced code block is syntax highlighted" do
      html = render_md(%{text: @json_fence})

      # Lumis wraps each token in a `<span>` whose color is a CSS `light-dark()`
      # pair. Unhighlighted MDEx output has no spans inside the `<code>` at all.
      assert html =~ "language-json"
      assert html =~ "lumis lumis-themes"
      assert html =~ "color: light-dark("

      # Punctuation, keys, string values and numbers must not all collapse to a
      # single foreground color - distinct colors are the point of highlighting.
      distinct_colors =
        ~r/color: (light-dark\([^)]*\))/
        |> Regex.scan(html, capture: :all_but_first)
        |> MapSet.new()

      assert MapSet.size(distinct_colors) >= 4
    end

    test "a code block with an unknown language still renders its content" do
      html = render_md(%{text: "```notalanguage\nhello world\n```"})

      assert html =~ "hello world"
    end

    test "streaming content is syntax highlighted too" do
      html = render_md(%{text: @json_fence, streaming: true})

      assert html =~ "color: light-dark("
    end
  end

  describe "thinking_display via message/1" do
    test "a persisted thinking message renders non-streaming" do
      # thinking_display/1 is shared between persisted thinking messages and the
      # in-flight thinking buffer, so it must default to non-streaming.
      html =
        render_component(&ChatComponents.message/1, %{
          message: %{
            id: 42,
            content_type: "thinking",
            content: %{"text" => @trailing_tilde}
          }
        })

      assert html =~ "~1,486"
      refute html =~ "<del>"
    end
  end

  describe "stop reason note via message/1" do
    defp render_message(content_type, content) do
      render_component(&ChatComponents.message/1, %{
        message: %{
          id: 42,
          message_type: "assistant",
          content_type: content_type,
          content: content
        }
      })
    end

    # query/2 rather than filter/2: filter keeps only matching *root* nodes, so
    # a descendant selector against it always comes back empty and every
    # negative assertion below would hold for the wrong reason.
    defp note_nodes(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.to_list()
    end

    test "the note is not a descendant of the collapsed thinking container" do
      # The reported failure: a response cut off inside a thinking block. That
      # block's body sits in a `hidden` div, so asserting only that the text
      # appears somewhere in the HTML passes while the note is invisible —
      # which is the original bug exactly. Assert the structure instead.
      html = render_message("thinking", %{"text" => "Working through", "stop_reason" => "length"})

      # Guard the negative assertion below against going vacuous: if the
      # collapsed container stopped rendering, or its id changed, the
      # descendant selector would match nothing for the wrong reason.
      assert [container] = note_nodes(html, "#thinking-42")
      assert LazyHTML.attribute(container, "class") |> List.first() =~ "hidden"

      assert [_note] = note_nodes(html, "[data-stop-reason]")
      assert [] == note_nodes(html, "#thinking-42 [data-stop-reason]")
    end

    test "a finished message renders no note" do
      html = render_message("text", %{"text" => "All done"})

      assert [] == note_nodes(html, "[data-stop-reason]")
    end

    test "each reason gets its own wording" do
      for {reason, expected} <- [
            {"length", "reached the length limit"},
            {"stream_error", "connection error"},
            {"cancelled", "Response stopped"},
            {"content_filtered", "Response declined"}
          ] do
        html = render_message("text", %{"text" => "Partial", "stop_reason" => reason})

        assert [node] = note_nodes(html, "[data-stop-reason=\"#{reason}\"]")
        assert LazyHTML.text(node) =~ expected
      end
    end

    test "a refusal names the category and keeps the explanation out of the line" do
      html =
        render_message("text", %{
          "text" => "I can't help with",
          "stop_reason" => "content_filtered",
          "stop_details" => %{
            "type" => "refusal",
            "category" => "cyber",
            "explanation" => "Declined to assist."
          }
        })

      assert [node] = note_nodes(html, "[data-stop-reason]")
      assert LazyHTML.text(node) =~ "Response declined (cyber)"
      refute LazyHTML.text(node) =~ "Declined to assist."
      assert [_titled] = note_nodes(html, "[title=\"Declined to assist.\"]")
    end

    test "a refusal with no category falls back to the bare wording" do
      html =
        render_message("text", %{
          "text" => "I can't help with",
          "stop_reason" => "content_filtered",
          "stop_details" => %{"type" => "refusal"}
        })

      assert [node] = note_nodes(html, "[data-stop-reason]")
      assert LazyHTML.text(node) =~ "Response declined"
    end
  end

  describe "streaming_message/1" do
    defp delta(parts) do
      %{streaming_delta: %MessageDelta{merged_content: parts, tool_calls: []}}
    end

    test "the in-flight text buffer renders in streaming mode" do
      html =
        render_component(
          &ChatComponents.streaming_message/1,
          delta([ContentPart.text!(@trailing_tilde)])
        )

      assert html =~ "<del>"
    end

    test "the in-flight thinking buffer renders in streaming mode" do
      html =
        render_component(
          &ChatComponents.streaming_message/1,
          delta([ContentPart.thinking!(@trailing_tilde)])
        )

      assert html =~ "<del>"
    end
  end

  describe "question_prompt/1 dormant-agent handling" do
    defp question(overrides \\ %{}) do
      Map.merge(
        %{
          tool_call_id: "call_abc",
          question: "Which database?",
          context: nil,
          response_type: :single_select,
          options: [
            %{value: "pg", label: "PostgreSQL", description: nil},
            %{value: "sqlite", label: "SQLite", description: nil}
          ],
          allow_other: true,
          allow_cancel: true
        },
        overrides
      )
    end

    defp render_question(overrides \\ %{}) do
      render_component(&ChatComponents.question_prompt/1, %{
        question: question(overrides),
        remaining_count: 0
      })
    end

    test "wraps the answer controls in an ignored region so typed text survives a patch" do
      html = render_question()

      # Without this, an unrelated assign change (notably agent_alive? flipping
      # when the agent naps) makes morphdom resync the "Other" textarea from the
      # server's HTML, which never contains what the user typed.
      assert html =~ ~s(phx-update="ignore")
    end

    test "keys the ignored region on the question's tool_call_id" do
      # The id is what lets the *next* question in a batch render at all:
      # morphdom replaces an ignored subtree only when its id changes.
      assert render_question() =~ ~s(id="question-body-call_abc")
      assert render_question(%{tool_call_id: "call_xyz"}) =~ ~s(id="question-body-call_xyz")
    end

    # LazyHTML.filter/2 only matches the top-level nodes of a fragment, so
    # descendant selectors are not available. Scan for the matching close tag
    # instead; it is exact and needs no dependency.
    defp ignored_region(html, tool_call_id) do
      open = ~s(id="question-body-#{tool_call_id}" phx-update="ignore">)
      {start, len} = :binary.match(html, open)
      after_open = binary_part(html, start + len, byte_size(html) - start - len)
      {inner, rest} = balanced_div(after_open, 1, "")
      {inner, rest}
    end

    defp balanced_div("</div>" <> rest, 1, acc), do: {acc, rest}

    defp balanced_div("</div>" <> rest, depth, acc),
      do: balanced_div(rest, depth - 1, acc <> "</div>")

    defp balanced_div("<div" <> rest, depth, acc),
      do: balanced_div(rest, depth + 1, acc <> "<div")

    defp balanced_div(<<c::utf8, rest::binary>>, depth, acc),
      do: balanced_div(rest, depth, acc <> <<c::utf8>>)

    defp balanced_div("", _depth, acc), do: {acc, ""}

    test "puts every typed-into control inside the ignored region" do
      {inner, _after} = ignored_region(render_question(), "call_abc")

      # The Other textarea is the element this whole treatment exists for.
      assert inner =~ "data-other-input"
      assert inner =~ ~s(name="selected")
      assert inner =~ ~s(phx-submit="question_single_submit")
    end

    test "keeps the Cancel action outside the ignored region so it can re-render" do
      # Cancel carries no typed state, and freezing it would stop it tracking
      # allow_cancel changing between questions in a batch.
      html = render_question()
      {inner, after_region} = ignored_region(html, "call_abc")

      refute inner =~ "question_cancel"
      assert after_region =~ "question_cancel"
    end

    test "puts the freeform textarea inside the ignored region" do
      html = render_question(%{response_type: :freeform, allow_other: false})
      {inner, _after} = ignored_region(html, "call_abc")

      assert inner =~ ~s(name="text")
      assert inner =~ ~s(phx-submit="question_freeform_submit")
    end
  end

  describe "chat_interface/1 wake affordance" do
    defp render_interface(overrides) do
      base = %{
        streams: %{messages: []},
        has_messages: false,
        input: "",
        loading: false,
        is_thread_history_open: false,
        streaming_delta: nil,
        agent_status: :idle,
        agent_alive?: true,
        pending_tools: [],
        pending_question: nil,
        remaining_questions_count: 0,
        interrupt_data: nil,
        current_scope: nil,
        conversation_id: "42",
        has_more_conversations: false,
        has_conversations: true,
        debug_mode: false
      }

      render_component(&ChatComponents.chat_interface/1, Map.merge(base, overrides))
    end

    test "hides Wake while a process is backing the conversation" do
      refute render_interface(%{agent_alive?: true}) =~ ~s(phx-click="wake_agent")
    end

    test "shows Wake whenever no process is backing the conversation" do
      assert render_interface(%{agent_alive?: false, agent_status: :not_running}) =~
               ~s(phx-click="wake_agent")
    end

    test "shows Wake for a dormant conversation that is still awaiting an answer" do
      # The regression this guards: gating on `agent_status == :not_running`
      # hid the button exactly when the conversation was asleep mid-question,
      # because that status stays :interrupted so the prompt can stay on screen.
      html =
        render_interface(%{
          agent_alive?: false,
          agent_status: :interrupted,
          pending_question: question()
        })

      assert html =~ ~s(phx-click="wake_agent")
    end

    test "hides Wake for a live interrupted conversation" do
      html =
        render_interface(%{
          agent_alive?: true,
          agent_status: :interrupted,
          pending_question: question()
        })

      refute html =~ ~s(phx-click="wake_agent")
    end

    test "hides Wake when there is no conversation at all" do
      refute render_interface(%{agent_alive?: false, conversation_id: nil}) =~
               ~s(phx-click="wake_agent")
    end
  end
end

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
end

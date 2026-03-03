defmodule AgentsDemo.Middleware.UserContextMiddleware do
  @moduledoc """
  Middleware that injects the user's first name into the first user message.

  This uses `before_model/2` to prepend a `<user_information>` XML tag to the
  first user message in the conversation. Injecting into user messages (rather
  than the system prompt) avoids prompt injection risks from user-controlled
  content in the system prompt.

  The injection only happens once — on the first user message — so subsequent
  turns are unaffected and prompt caching is preserved.

  ## Configuration

  - `:scope` - The Phoenix `Scope` struct containing the current user.

  ## Example

      middleware = [
        {AgentsDemo.Middleware.UserContextMiddleware, [scope: current_scope]},
        # ... other middleware
      ]
  """
  @behaviour Sagents.Middleware

  alias LangChain.Message.ContentPart
  alias Sagents.State

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope)
    first_name = get_in(scope, [Access.key(:user), Access.key(:first_name)])
    {:ok, %{first_name: first_name}}
  end

  @impl true
  def before_model(state, config) do
    if config.first_name do
      {:ok, maybe_prepend_user_context(state, config.first_name)}
    else
      {:ok, state}
    end
  end

  # Prepend user context to the first user message, but only when it's the last
  # message (i.e., it was just added). On subsequent turns the first user message
  # is no longer last, so it won't be modified again — preserving prompt caching.
  defp maybe_prepend_user_context(%State{messages: messages} = state, first_name) do
    last = List.last(messages)

    if last && last.role == :user && !has_prior_user_message?(messages) do
      context_text = "<user_information>The user's first name is #{first_name}.</user_information>\n\n"
      updated = %{last | content: prepend_context(last.content, context_text)}
      %{state | messages: List.replace_at(messages, -1, updated)}
    else
      state
    end
  end

  # Insert a new text ContentPart at the front rather than mutating existing parts.
  defp prepend_context(content, text) when is_binary(content) do
    text <> content
  end

  defp prepend_context(parts, text) when is_list(parts) do
    [ContentPart.text!(text) | parts]
  end

  defp prepend_context(nil, text) do
    text
  end

  defp has_prior_user_message?(messages) do
    messages
    |> Enum.drop(-1)
    |> Enum.any?(&(&1.role == :user))
  end
end

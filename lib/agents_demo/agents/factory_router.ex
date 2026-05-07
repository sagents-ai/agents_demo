defmodule AgentsDemo.Agents.FactoryRouter do
  @moduledoc """
  Routes a conversation to the factory module that should build its agent.

  The Coordinator consults this router on every session start (including
  resume), so a restored conversation always picks the factory it was
  originally created with — same system prompt, tools, middleware.

  This stub uses `Sagents.Routers.Single` for single-factory apps.
  Replace with a hand-written `resolve/3` if you need to route among
  multiple factories. A common multi-factory pattern is:

      defmodule AgentsDemo.Agents.FactoryRouter do
        @behaviour Sagents.FactoryRouter

        alias MyApp.Conversations

        @impl true
        def resolve(scope, conversation_id, request_opts) do
          conversation = Conversations.get_conversation!(scope, conversation_id)

          factory =
            case conversation.agent_kind do
              "coding" -> MyApp.Agents.CodingFactory
              "writing" -> MyApp.Agents.WritingFactory
              _ -> MyApp.Agents.DefaultFactory
            end

          factory_opts =
            request_opts
            |> Keyword.put(:conversation_id, conversation_id)
            |> Keyword.put(:conversation, conversation)

          {:ok, factory, factory_opts}
        end
      end

  See `Sagents.FactoryRouter` for the full contract.
  """

  use Sagents.Routers.Single, factory: AgentsDemo.Agents.Factory
end

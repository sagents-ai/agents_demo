defmodule AgentsDemo.Agents.FactoryRouter do
  @moduledoc """
  Routes a conversation to the factory module that should build its agent.

  Sagents.Session consults this router on every session start (including
  resume), so a restored conversation always picks the factory it was
  originally created with — same system prompt, tools, middleware.

  This stub uses `Sagents.Routers.Single` for single-factory apps. The
  generated `resolve/3` builds a `%AgentsDemo.Agents.FactoryConfig{}` from
  the router's inputs and pairs it with `AgentsDemo.Agents.Factory`.

  Replace the `use` below with a hand-written `resolve/3` if you need to
  route among multiple factories. A common multi-factory pattern is:

      defmodule AgentsDemo.Agents.FactoryRouter do
        @behaviour Sagents.FactoryRouter

        alias AgentsDemo.Conversations
        alias AgentsDemo.Agents.{CodingFactory, CodingConfig}
        alias AgentsDemo.Agents.{WritingFactory, WritingConfig}
        alias AgentsDemo.Agents.{DefaultFactory, DefaultConfig}

        @impl true
        def resolve(scope, conversation_id, request_opts) do
          conversation =
            AgentsDemo.Conversations.get_conversation!(scope, conversation_id)

          {factory, config_module} =
            case conversation.agent_kind do
              "coding" -> {CodingFactory, CodingConfig}
              "writing" -> {WritingFactory, WritingConfig}
              _ -> {DefaultFactory, DefaultConfig}
            end

          inputs =
            request_opts
            |> Map.new()
            |> Map.put(:scope, scope)
            |> Map.put(:conversation_id, conversation_id)
            |> Map.put(:conversation, conversation)

          case config_module.from_inputs(inputs) |> config_module.build() do
            {:ok, config} -> {:ok, factory, config}
            {:error, %Ecto.Changeset{}} = err -> err
          end
        end
      end

  See `Sagents.FactoryRouter` for the full contract.
  """

  use Sagents.Routers.Single,
    factory: AgentsDemo.Agents.Factory,
    config: AgentsDemo.Agents.FactoryConfig
end

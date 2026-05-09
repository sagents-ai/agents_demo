defmodule AgentsDemo.Agents.Factory do
  @behaviour Sagents.Factory

  @moduledoc """
  Factory for creating agents with consistent configuration.

  Pairs with `AgentsDemo.Agents.FactoryConfig` — read that module to know
  what's required and how to build a config. This factory just consumes
  `%FactoryConfig{}` and produces a `%Sagents.Agent{}`.

  This module centralizes agent creation, ensuring all agents use the
  same model, middleware stack, and base configuration. Sagents.Session
  calls `create_agent/2` when starting a conversation session.

  This Factory is automatically configured for your persistence layer:
  - Owner type: :user
  - Owner field: user_id
  - Conversations context: AgentsDemo.Conversations

  ## Customization

  Each helper takes the `%FactoryConfig{}` config (`c`)
  so you can branch on per-request fields without re-threading args:

  - Change model provider in `build_model/1`
  - Configure fallbacks in `get_fallback_models/1`
  - Configure title generation model in `get_title_model/1`
  - Modify system prompt in `base_system_prompt/1`
  - Add/remove middleware in `build_middleware/1`
  - Add custom tools in `build_tools/1`
  - Configure HITL in `default_interrupt_on/1`

  ## Understanding the Default Middleware

  The middleware stack below replicates `Sagents.Agent.build_default_middleware/3`.
  You can call that function in IEx to see the canonical defaults:

      middleware = Sagents.Agent.build_default_middleware(model, "test-agent")

  ## Model Fallback Strategy

  The fallback configuration uses the *same model* on a different provider
  for resilience without changing behavior:

  | Primary Provider      | Fallback Provider       |
  |-----------------------|-------------------------|
  | ChatAnthropic (API)   | ChatAnthropic (Bedrock) |
  | ChatOpenAI (API)      | ChatOpenAI (Azure)      |

  ## Filesystem Scoping

  Files are scoped to the owner (`{:user, user_id}`)
  so they persist across all conversations for that owner. Edit
  `ensure_filesystem_for/1` to change the scoping strategy.

  """

  alias LangChain.ChatModels.ChatAnthropic
  # Uncomment for OpenAI:
  # alias LangChain.ChatModels.ChatOpenAI
  # Uncomment for Bedrock:
  # alias LangChain.Utils.BedrockConfig
  alias AgentsDemo.Agents.DemoSetup
  alias AgentsDemo.Middleware.InjectCurrentTime
  alias AgentsDemo.Middleware.WebToolMiddleware
  alias Sagents.Agent
  alias Sagents.Middleware.ConversationTitle
  alias Sagents.Middleware.HumanInTheLoop
  alias AgentsDemo.Agents.FactoryConfig

  require Logger

  # ---------------------------------------------------------------------------
  # Model Configuration (edit these module attributes to change models)
  # ---------------------------------------------------------------------------

  # Primary model for agent conversations
  # See: https://docs.anthropic.com/en/docs/models-overview
  @main_model "claude-sonnet-4-6"

  # Title generation uses a lighter/faster model for cost efficiency
  # Haiku is ~10x cheaper than Sonnet and sufficient for generating titles
  @title_model "claude-haiku-4-5"

  @doc """
  Builds a `%Sagents.Agent{}` from the supplied config.

  - `agent_id` is system-supplied by `Sagents.Session` (derived from
    `conversation_id` via the host's `agent_id_fun`).
  - `config` is a `%FactoryConfig{}` produced by the
    paired `FactoryRouter` (typically via
    `FactoryConfig.from_inputs/1 |> FactoryConfig.build/1`).
  """
  @impl Sagents.Factory
  def create_agent(agent_id, %FactoryConfig{} = c) do
    Agent.new(
      %{
        agent_id: agent_id,
        scope: c.scope,
        model: build_model(c),
        base_system_prompt: base_system_prompt(c),
        middleware: build_middleware(c),
        name: "Demo Agent",
        fallback_models: get_fallback_models(c),
        before_fallback: get_before_fallback(c),
        # Add any custom tools here (tools not provided by middleware)
        tools: build_tools(c),
        tool_context: c.tool_context
      },
      # Since we specify the full middleware stack, don't add defaults
      replace_default_middleware: true
    )
    |> case do
      {:ok, agent} -> {:ok, agent, []}
      {:error, _reason} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Filesystem
  # ---------------------------------------------------------------------------

  # Ensure the owner-scoped filesystem is running before the agent boots.
  # Returns a `scope_key` tuple to pass into the FileSystem middleware, or
  # `nil` to fall back to agent-scoped filesystem.
  defp ensure_filesystem_for(%FactoryConfig{
         scope: %{user: %{id: user_id}}
       })
       when not is_nil(user_id) do
    case DemoSetup.ensure_user_filesystem(user_id) do
      {:ok, scope_key} ->
        scope_key

      {:error, reason} ->
        Logger.warning(
          "Factory could not ensure user filesystem (user_id=#{user_id}): #{inspect(reason)}. " <>
            "Falling back to agent-scoped filesystem."
        )

        nil
    end
  end

  defp ensure_filesystem_for(_c), do: nil

  # ---------------------------------------------------------------------------
  # Model Configuration
  # ---------------------------------------------------------------------------

  # Primary model configuration.
  # Modify this function to switch providers or models. Branch on `c` to
  # vary the model per request (e.g. agent kind, plan tier).
  defp build_model(%FactoryConfig{} = _c) do
    ChatAnthropic.new!(%{
      model: @main_model,
      api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
      stream: true,
      cache_control: %{"type" => "ephemeral"},
      thinking: %{
        type: "enabled",
        budget_tokens: 3_000
      }
    })
  end

  defp get_fallback_models(%FactoryConfig{} = _c) do
    []
  end

  defp get_before_fallback(%FactoryConfig{} = _c) do
    nil
  end

  # ---------------------------------------------------------------------------
  # Title Generation Model
  # ---------------------------------------------------------------------------

  defp get_title_model(%FactoryConfig{} = _c) do
    ChatAnthropic.new!(%{
      model: @title_model,
      api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
      temperature: 1,
      stream: false
    })
  end

  defp get_title_fallbacks(%FactoryConfig{} = _c), do: []

  # ---------------------------------------------------------------------------
  # System Prompt
  # ---------------------------------------------------------------------------

  # Base system prompt for all agents. Branch on `c` for per-request
  # customizations (e.g. inject project context).
  defp base_system_prompt(%FactoryConfig{} = _c) do
    """
    You are a helpful AI assistant with access to a persistent memory system and web search capabilities.

    You can read, write, and manage files in the /Memories directory.
    You can search the web for current information using the web_lookup tool.

    Be friendly, helpful, and demonstrate your capabilities when appropriate.
    When users ask about current information, recent events, or facts that may have changed,
    use the web_lookup tool to get accurate, up-to-date information.
    """
  end

  # ---------------------------------------------------------------------------
  # Human-in-the-Loop Configuration
  # ---------------------------------------------------------------------------

  # Default tools that require human approval before execution.
  # Return `nil` or `%{}` to disable HITL entirely.
  #
  # Configuration options:
  #   - `true` - Enable with default decisions (approve, edit, reject)
  #   - `false` - No interruption for this tool
  #   - `%{allowed_decisions: [:approve, :reject]}` - Custom decisions
  defp default_interrupt_on(%FactoryConfig{} = _c) do
    %{
      "delete_file" => true
      # "write_file" => true,
      # "execute_command" => true
    }
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  # Custom (non-middleware-provided) tools. Branch on `c` to enable/disable
  # tools per request.
  defp build_tools(%FactoryConfig{} = _c), do: []

  # ---------------------------------------------------------------------------
  # Middleware Configuration
  # ---------------------------------------------------------------------------

  defp build_middleware(%FactoryConfig{} = c) do
    filesystem_scope = ensure_filesystem_for(c)
    interrupt_on = default_interrupt_on(c)

    [
      # Include display of the TODO list as inline in the chat
      {Sagents.Middleware.TodoList, [inline: true]},
      {ConversationTitle,
       [
         chat_model: get_title_model(c),
         fallbacks: get_title_fallbacks(c)
       ]},
      {Sagents.Middleware.FileSystem,
       [
         enabled_tools: [
           "list_files",
           "read_file",
           "create_file",
           #  "insert_file_lines",
           "find_in_file",
           "move_file",
           "delete_file"
         ],
         filesystem_scope: filesystem_scope
       ]},
      {Sagents.Middleware.SubAgent,
       [
         block_middleware: [
           AgentsDemo.Middleware.WebToolMiddleware,
           AgentsDemo.Middleware.InjectCurrentTime,
           AgentsDemo.Middleware.UserContextMiddleware,
           Sagents.Middleware.Summarization,
           Sagents.Middleware.ConversationTitle,
           Sagents.Middleware.AskUserQuestion
         ]
       ]},
      {AgentsDemo.Middleware.UserContextMiddleware, [scope: c.scope]},
      {InjectCurrentTime, [timezone: c.timezone]},
      WebToolMiddleware,
      Sagents.Middleware.Summarization,
      Sagents.Middleware.PatchToolCalls,
      Sagents.Middleware.AskUserQuestion
    ]
    # HumanInTheLoop MUST be last. During resume, HITL executes all tools
    # (including auto-approved ones from other middleware). If those tools produce
    # interrupts (e.g., ask_user), HITL hands off via {:cont} to the next middleware
    # in the resume cycle. Middleware that already ran (earlier in the list) won't
    # get a second chance, so interrupt-producing middleware must come before HITL.
    |> HumanInTheLoop.maybe_append(interrupt_on)
  end
end

defmodule AgentsDemo.Agents.Factory do
  @moduledoc """
  Factory for creating agents with appropriate middleware and tools.

  This module centralizes agent creation logic, ensuring consistency
  between new conversations and restored conversations.
  """

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Agents.Agent
  alias LangChain.Agents.Middleware.ConversationTitle
  alias AgentsDemo.Middleware.WebToolMiddleware
  alias LangChain.Utils.BedrockConfig

  # New Anthropic models to use
  @claude_model "claude-sonnet-4-5-20250929"

  # Same models as used in Application
  @title_model "claude-3-5-haiku-latest"
  @title_fallback_model "us.anthropic.claude-3-5-haiku-20241022-v1:0"

  @doc """
  Creates an agent for the demo application.

  This function is used for both new and restored conversations.
  The agent capabilities (middleware, tools, model) come from
  current application code, not from the database.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:agent_id` - Required. The agent's runtime identifier.
    - `:interrupt_on` - Optional. Map of tool names to interrupt configs (default: write_file and delete_file).
    - `:filesystem_scope` - Optional. Scope tuple for filesystem reference (e.g., {:user, 123}).

  ## Examples

      # For new conversation
      {:ok, agent} = Factory.create_demo_agent(agent_id: "demo-123")

      # For restored conversation (same function!)
      {:ok, agent} = Factory.create_demo_agent(agent_id: "demo-123")

      # With filesystem scope
      {:ok, agent} = Factory.create_demo_agent(agent_id: "demo-123", filesystem_scope: {:user, 1})

      # Without human-in-the-loop
      {:ok, agent} = Factory.create_demo_agent(agent_id: "demo-123", interrupt_on: nil)
  """
  def create_demo_agent(opts \\ []) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    # Default to requiring approval for file writes and deletes
    interrupt_on = Keyword.get(opts, :interrupt_on, %{
      "write_file" => false,
      "delete_file" => true
    })
    filesystem_scope = Keyword.get(opts, :filesystem_scope)

    # Get model configuration from environment
    model = get_model_config()

    # Build agent with current middleware from code
    Agent.new(
      %{
        agent_id: agent_id,
        model: model,
        base_system_prompt: """
        You are a helpful AI assistant with access to a persistent memory system and web search capabilities.

        You can read, write, and manage files in the /Memories directory.
        You can search the web for current information using the web_lookup tool.

        Be friendly, helpful, and demonstrate your capabilities when appropriate.
        When users ask about current information, recent events, or facts that may have changed,
        use the web_lookup tool to get accurate, up-to-date information.
        """,
        name: "Demo Agent",
        # Middleware is defined here in code, not loaded from database
        middleware: build_demo_middleware(interrupt_on, filesystem_scope),
        # Add any custom tools here
        tools: []
      },
      # IMPORTANT: Since we're explicitly specifying ALL middleware above,
      # we must tell Agent.new not to add default middleware again
      replace_default_middleware: true
    )
  end

  defp build_demo_middleware(interrupt_on, filesystem_scope) do
    api_key = System.fetch_env!("ANTHROPIC_API_KEY")

    # Configure FileSystem middleware based on scope
    filesystem_middleware =
      if filesystem_scope do
        # Scope-based filesystem (references independently-running filesystem)
        {LangChain.Agents.Middleware.FileSystem, [filesystem_scope: filesystem_scope]}
      else
        # Default behavior (agent-scoped filesystem)
        LangChain.Agents.Middleware.FileSystem
      end

    # Use the full middleware stack that matches application.ex
    # This ensures consistency between new and restored conversations
    base_middleware = [
      LangChain.Agents.Middleware.TodoList,
      filesystem_middleware,
      LangChain.Agents.Middleware.SubAgent,
      LangChain.Agents.Middleware.Summarization,
      LangChain.Agents.Middleware.PatchToolCalls
    ]

    # Add HumanInTheLoop if interrupts configured
    middleware =
      if interrupt_on do
        base_middleware ++
          [{LangChain.Agents.Middleware.HumanInTheLoop, [interrupt_on: interrupt_on]}]
      else
        base_middleware
      end

    # Add application-specific middleware (WebTool and ConversationTitle)
    middleware ++
      [
        WebToolMiddleware,
        {ConversationTitle,
         [
           chat_model: get_title_model(api_key),
           fallbacks: get_title_fallbacks()
         ]}
      ]
  end

  # Get the primary title generation model (matches application.ex)
  defp get_title_model(api_key) do
    ChatAnthropic.new!(%{
      model: @title_model,
      api_key: api_key,
      temperature: 1,
      stream: false
    })
  end

  # Get the list of fallback title generation models (matches application.ex)
  defp get_title_fallbacks() do
    [
      ChatAnthropic.new!(%{
        model: @title_fallback_model,
        bedrock: BedrockConfig.from_application_env!(),
        temperature: 1,
        stream: false
      })
    ]
  end

  defp get_model_config do
    ChatAnthropic.new!(%{
      model: @claude_model,
      api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
      thinking: %{type: "enabled", budget_tokens: 2000},
      temperature: 1,
      stream: true
    })
  end
end

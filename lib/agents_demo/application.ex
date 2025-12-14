defmodule AgentsDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Agents.Agent
  alias LangChain.Agents.AgentSupervisor
  alias LangChain.Agents.FileSystem.FileSystemConfig
  alias LangChain.Agents.FileSystem.Persistence.Disk
  alias AgentsDemo.Middleware.WebToolMiddleware
  alias LangChain.Utils.BedrockConfig

  # New anthropic models to use
  @claude_model "claude-sonnet-4-5-20250929"
  # @bedrock_claude_model "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

  # # # anthropic models to use
  # # @claude_model "claude-3-7-sonnet-latest"
  # # @bedrock_claude_model "us.anthropic.claude-3-7-sonnet-20250219-v1:0"

  # Title models
  @title_model "claude-3-5-haiku-latest"
  @title_fallback_model "us.anthropic.claude-3-5-haiku-20241022-v1:0"

  @impl true
  def start(_type, _args) do
    # Configure the agent and filesystem
    agent_config = build_agent_config()

    children = [
      AgentsDemoWeb.Telemetry,
      AgentsDemo.Repo,
      {DNSCluster, query: Application.get_env(:agents_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AgentsDemo.PubSub},
      # Start the Registry for agent processes
      {Registry, keys: :unique, name: LangChain.Agents.Registry},
      # Start the AgentSupervisor with FileSystem support
      {AgentSupervisor, agent_config},
      # Start to serve requests, typically the last entry
      AgentsDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AgentsDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentsDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Build the agent configuration with FileSystem support
  defp build_agent_config do
    # Get the API key from environment (or use a dummy value for development)
    api_key = System.get_env("ANTHROPIC_API_KEY") || "dummy-key-for-dev"

    # Create the ChatModel
    model =
      ChatAnthropic.new!(%{
        model: @claude_model,
        thinking: %{type: "enabled", budget_tokens: 2000},
        api_key: api_key,
        temperature: 1,
        stream: true
      })

    # Create initial state (no longer storing title config in metadata)
    initial_state = LangChain.Agents.State.new!(%{})

    # Create the Agent with title configuration as first-class config
    agent =
      Agent.new!(
        %{
          agent_id: "demo-agent-001",
          model: model,
          system_prompt: """
          You are a helpful AI assistant with access to a persistent memory system and web search capabilities.

          You can read, write, and manage files in the /Memories directory.
          You can search the web for current information using the web_lookup tool.

          Be friendly, helpful, and demonstrate your capabilities when appropriate.
          When users ask about current information, recent events, or facts that may have changed,
          use the web_lookup tool to get accurate, up-to-date information.
          """,
          name: "Demo Agent",
          middleware: [WebToolMiddleware],
          # Create title generation LLMs
          title_chat_model: get_title_model(api_key),
          title_fallbacks: get_title_fallbacks()
        },
        # Adding "Human In The Loop" (hitl) control for writing and deleting
        # files
        interrupt_on: %{
          "write_file" => true,
          "delete_file" => true
        }
      )

    # Get the absolute path to the demo_memories directory
    # priv_dir returns the priv directory for the application
    priv_dir = :code.priv_dir(:agents_demo) |> to_string()
    storage_path = Path.join([priv_dir, "static", "public", "demo_memories"])

    # Ensure the directory exists
    File.mkdir_p!(storage_path)

    # Create the FileSystemConfig for the Memories virtual directory
    {:ok, fs_config} =
      FileSystemConfig.new(%{
        base_directory: "Memories",
        persistence_module: Disk,
        debounce_ms: 5000,
        storage_opts: [path: storage_path]
      })

    Logger.info("Agent configured with FileSystem at: #{storage_path}")
    Logger.info("Virtual filesystem mounted at: /Memories")

    # Return the agent supervisor configuration
    [
      agent: agent,
      initial_state: initial_state,
      persistence_configs: [fs_config],
      pubsub: Phoenix.PubSub,
      pubsub_name: AgentsDemo.PubSub,
      # The demo only works with 1 agent. Keep it running with the application.
      inactivity_timeout: :infinity
    ]
  end

  # Get the primary title generation model
  defp get_title_model(api_key) do
    ChatAnthropic.new!(%{
      model: @title_model,
      api_key: api_key,
      temperature: 1,
      stream: false
    })
  end

  # Get the list of fallback title generation models
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
end

defmodule AgentsDemo.Middleware.WebToolMiddleware do
  @moduledoc """
  Middleware that provides web lookup capabilities to agents.

  Offers a single `web_lookup` tool that searches the web, selects
  the best result, fetches the page, and extracts relevant information.

  ## Usage

  Simply add the middleware when creating an agent:

      {:ok, agent} = Agent.new(%{
        model: model,
        middleware: [AgentsDemo.Middleware.WebToolMiddleware]
      })

  The agent will automatically have access to the `web_lookup` tool.
  When the agent needs current information, it will use this tool which:

  1. Searches the web using DuckDuckGo
  2. Selects the most authoritative result
  3. Fetches the page content
  4. Extracts relevant information
  5. Returns formatted result with source attribution

  ## Tool Parameters

  - `query` (required) - What to search for
  - `focus` (optional) - Specific aspect to extract from the page

  ## Output Format

      Source: [Page Title]
      URL: [Page URL]

      [Extracted Information]

  ## Features

  - Single tool interface for complete web lookup workflow
  - Automated source selection (prefers authoritative sources)
  - Structured results with source attribution
  - Isolated subagent execution for security
  - No file system or bash access in subagent
  - JSON validation and error handling

  ## Security

  The subagent that performs web lookups:
  - Runs in an isolated process
  - Has NO file system access
  - Has NO bash/system command access
  - Only has `search_web` and `fetch_page` tools
  - Cannot access parent agent's conversation history

  ## Good Use Cases

  - Current events: "Who won the latest Formula 1 race?"
  - Recent releases: "What's new in Elixir 1.17?"
  - Current statistics: "What's the current population of Tokyo?"
  - Documentation: "How do I use Ecto.Multi?"
  - Facts that change: "What's the current world record for marathon?"

  ## Not Ideal For

  - Historical facts already in training data
  - General knowledge that doesn't require current information
  - Deep research needing multiple sources (use Web Researcher Middleware)
  - Tasks requiring iterative refinement

  ## Tests

  See `test/agents_demo/middleware/web_tool_middleware_test.exs` for 58
  comprehensive tests covering all functionality, validation, and edge cases.
  """
  @behaviour LangChain.Agents.Middleware

  @default_timeout 60_000

  require Logger
  alias LangChain.Function
  alias LangChain.Agents.SubAgent

  @system_prompt """
  ## Web Lookup Tool

  You have access to a web_lookup tool for retrieving current information from the web.

  **web_lookup**: Search the web, fetch the most relevant page, and extract key information

  Use this tool when you need:
  - Current events, news, or recent developments
  - Up-to-date facts, statistics, or records
  - Recent documentation or technical information
  - Information beyond your training cutoff

  Input parameters:
  - query: What to search for (required)
  - focus: Specific aspect to extract (optional, but recommended for precise results)

  The tool will:
  1. Search the web for your query
  2. Select the most authoritative result
  3. Fetch and analyze that page
  4. Extract relevant information
  5. Return the information with source citation

  Example:
  query: "Elixir 1.19 release date"
  focus: "release date and major features"

  The tool handles the entire workflow automatically and returns structured information.
  """

  @impl true
  def init(opts) do
    # Required options
    agent_id = Keyword.fetch!(opts, :agent_id)
    model = Keyword.fetch!(opts, :model)

    # Build the compiled web lookup subagent
    web_lookup_agent = build_web_lookup_agent(model)

    compiled_subagent =
      SubAgent.Compiled.new!(%{
        name: "web-lookup",
        description: "Search web, select best source, fetch page, extract information",
        agent: web_lookup_agent,
        initial_messages: []
      })

    config = %{
      agent_id: agent_id,
      model: model,
      compiled_subagent: compiled_subagent,
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }

    {:ok, config}
  end

  @impl true
  def system_prompt(_config) do
    @system_prompt
  end

  @impl true
  def tools(config) do
    [
      build_web_lookup_tool(config)
    ]
  end

  @impl true
  def state_schema do
    # No state needed for this middleware
    []
  end

  # Tool builder

  defp build_web_lookup_tool(config) do
    Function.new!(%{
      name: "web_lookup",
      description: """
      Search the web, fetch the most relevant page, and extract key information.

      Returns structured information with source attribution.
      """,
      parameters_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "What to search for"
          },
          focus: %{
            type: "string",
            description: "Optional: specific aspect to extract from the page"
          }
        },
        required: ["query"]
      },
      function: fn args, context ->
        execute_web_lookup(args, context, config)
      end
    })
  end

  # Tool execution

  defp execute_web_lookup(args, context, config) do
    query = get_arg(args, "query")
    focus = get_arg(args, "focus") || "key information"

    if is_nil(query) or String.trim(query) == "" do
      {:error, "query parameter is required and cannot be empty"}
    else
      # Use SubAgent middleware to spawn and execute the web lookup subagent
      perform_web_lookup(query, focus, context, config)
    end
  end

  defp perform_web_lookup(query, focus, context, config) do
    # Build the instructions for the subagent
    instructions = build_sub_agent_instructions(query, focus)

    # Prepare arguments for SubAgent.start_subagent/5
    subagent_args = %{
      "instructions" => instructions,
      "subagent_type" => "web-lookup"
    }

    # Build subagent_config for SubAgent middleware
    subagent_config = %{
      agent_map: %{"web-lookup" => config.compiled_subagent},
      descriptions: %{"web-lookup" => config.compiled_subagent.description},
      agent_id: config.agent_id,
      model: config.model
    }

    # Call the public SubAgent.start_subagent/5 function
    # This handles spawning, execution, and cleanup
    case LangChain.Agents.Middleware.SubAgent.start_subagent(
           instructions,
           "web-lookup",
           subagent_args,
           context,
           subagent_config
         ) do
      {:ok, result} ->
        # Result is a string - parse and validate it as JSON
        parse_and_validate_result(result)

      {:interrupt, interrupt_data} ->
        # Propagate interrupt (shouldn't happen for this subagent)
        {:interrupt, interrupt_data}

      {:error, reason} ->
        {:error, "Web lookup failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Web lookup failed: #{Exception.message(e)}"}
  end

  # Helper functions for building compiled subagent

  defp build_web_lookup_agent(model) do
    # Build an agent with custom tools for web lookup
    # This agent has NO middleware, only the specific tools it needs
    LangChain.Agents.Agent.new!(
      %{
        model: model,
        base_system_prompt: web_lookup_system_prompt(),
        tools: [search_web_tool(), fetch_page_tool()],
        middleware: []
      },
      replace_default_middleware: true
    )
  end

  defp web_lookup_system_prompt do
    """
    You are a web information retriever. Your task is to:

    1. Search the web for information
    2. Select the most authoritative source from results
    3. Fetch and analyze the page content
    4. Extract relevant information
    5. Return a structured JSON response

    Always return ONLY valid JSON in the exact format specified, nothing else.
    """
  end

  # Sub-agent instructions template

  defp build_sub_agent_instructions(query, focus) do
    """
    You are a web information retriever. Your task:

    1. SEARCH: Use search_web tool with the query: "#{query}"

    2. SELECT: Review the search results and identify the most authoritative source:
       - Prefer well-known, reputable domains
       - Look for official documentation, major news sites, or academic sources
       - Avoid user-generated content sites, forums, or low-quality sources
       - Select the single best result

    3. FETCH: Use fetch_page tool to retrieve the selected page as markdown

    4. EXTRACT: Analyze the page content and extract information relevant to:
       - Main query: #{query}
       - Specific focus: #{focus}

       Extract only the most relevant and important information. Be concise but complete.
       Include specific facts, numbers, dates, and names when relevant.

    5. RETURN: Provide your response as a JSON object with this exact structure:
       {
         "status": "success",
         "source_title": "The page title",
         "source_url": "The full URL",
         "information": "The extracted relevant information (2-4 sentences typically)",
         "search_performed": "The query you searched for"
       }

    If you encounter errors (no results, page failed to load, etc.), return:
    {
      "status": "error",
      "source_title": "",
      "source_url": "",
      "information": "Description of what went wrong",
      "search_performed": "The query you attempted"
    }

    IMPORTANT: Return ONLY the JSON object, nothing else.
    """
  end

  # Custom tools for sub-agent

  @doc false
  def search_web_tool do
    # This tool will be provided to the sub-agent
    # It wraps AgentsDemo.WebTool.fetch_search_results/1
    Function.new!(%{
      name: "search_web",
      description: "Search DuckDuckGo and return structured results with links",
      parameters_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query"
          }
        },
        required: ["query"]
      },
      function: fn args, _context ->
        query = get_arg(args, "query")

        # fetch_search_results always returns {:ok, results}
        # The status field inside results indicates success/error
        {:ok, results} = AgentsDemo.WebTool.fetch_search_results(query)
        {:ok, Jason.encode!(results)}
      end
    })
  end

  @doc false
  def fetch_page_tool do
    # This tool will be provided to the sub-agent
    # It wraps AgentsDemo.WebTool.fetch_webpage/1
    Function.new!(%{
      name: "fetch_page",
      description: "Fetch a webpage and return its content as markdown",
      parameters_schema: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "The URL to fetch"
          }
        },
        required: ["url"]
      },
      function: fn args, _context ->
        url = get_arg(args, "url")

        case AgentsDemo.WebTool.fetch_webpage(url) do
          {:ok, markdown} ->
            {:ok, markdown}

          {:error, reason} ->
            {:error, "Failed to fetch page: #{reason}"}
        end
      end
    })
  end

  # Result parsing and validation
  # Since custom extractors aren't fully integrated into SubAgentServer yet,
  # we parse and validate the JSON result after receiving it from the subagent

  @doc false
  def parse_and_validate_result(result_text) when is_binary(result_text) do
    # Extract JSON from the response (might have extra text)
    json_text = extract_json_block(result_text)

    case Jason.decode(json_text) do
      {:ok, %{"status" => "success"} = data} ->
        # Validate required fields for success response
        case validate_success_fields(data) do
          :ok -> {:ok, format_success_response(data)}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{"status" => "error", "information" => info}} ->
        # Error response from subagent
        {:error, "Web lookup error: #{info}"}

      {:ok, _} ->
        {:error, "Invalid response format: missing or invalid 'status' field"}

      {:error, _} ->
        {:error, "Sub-agent returned invalid JSON: #{String.slice(result_text, 0..100)}..."}
    end
  end

  # Extract JSON block from text (handles cases where LLM adds extra text)
  @doc false
  def extract_json_block(text) do
    # Try to find JSON object boundaries
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      nil -> text
    end
  end

  @doc false
  def validate_success_fields(%{
        "source_title" => title,
        "source_url" => url,
        "information" => info
      })
      when is_binary(title) and is_binary(url) and is_binary(info) do
    cond do
      String.trim(title) == "" ->
        {:error, "source_title cannot be empty"}

      String.trim(url) == "" ->
        {:error, "source_url cannot be empty"}

      String.trim(info) == "" ->
        {:error, "information cannot be empty"}

      true ->
        :ok
    end
  end

  @doc false
  def validate_success_fields(_) do
    {:error, "Missing required fields: source_title, source_url, information"}
  end

  @doc false
  def format_success_response(data) do
    """
    Source: #{data["source_title"]}
    URL: #{data["source_url"]}

    #{data["information"]}
    """
  end

  # Utilities

  defp get_arg(args, key) when is_map(args) do
    Map.get(args, key) || Map.get(args, String.to_atom(key))
  end

  defp get_arg(_args, _key), do: nil
end

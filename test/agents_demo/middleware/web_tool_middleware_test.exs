defmodule AgentsDemo.Middleware.WebToolMiddlewareTest do
  use ExUnit.Case, async: true

  alias AgentsDemo.Middleware.WebToolMiddleware
  alias Sagents.Agent
  alias LangChain.ChatModels.ChatAnthropic

  describe "middleware behavior callbacks" do
    setup do
      model = ChatAnthropic.new!(%{model: "claude-3-haiku-20240307"})

      opts = [
        agent_id: "test-agent-123",
        model: model,
        middleware: []
      ]

      {:ok, config} = WebToolMiddleware.init(opts)
      {:ok, config: config}
    end

    test "init/1 creates middleware config with compiled subagent", %{config: config} do
      assert is_map(config)
      assert config.agent_id == "test-agent-123"
      assert is_struct(config.model, ChatAnthropic)
      assert is_struct(config.compiled_subagent, Sagents.SubAgent.Compiled)
      assert config.compiled_subagent.name == "web-lookup"
      assert config.timeout == 60_000
    end

    test "system_prompt/1 returns instructions for the agent", %{config: config} do
      prompt = WebToolMiddleware.system_prompt(config)

      assert is_binary(prompt)
      assert String.contains?(prompt, "web_lookup")
      assert String.contains?(prompt, "query")
      assert String.contains?(prompt, "focus")
    end

    test "tools/1 returns a list with web_lookup tool", %{config: config} do
      tools = WebToolMiddleware.tools(config)

      assert is_list(tools)
      assert length(tools) == 1

      [tool] = tools
      assert tool.name == "web_lookup"
      assert is_binary(tool.description)
      assert is_map(tool.parameters_schema)
      assert tool.parameters_schema.required == ["query"]
    end

    test "state_schema/0 returns empty list (no state needed)" do
      assert WebToolMiddleware.state_schema() == []
    end
  end

  describe "extract_json_block/1" do
    test "extracts JSON from clean input" do
      text = ~s({"status": "success", "info": "data"})
      result = WebToolMiddleware.extract_json_block(text)
      assert result == ~s({"status": "success", "info": "data"})
    end

    test "extracts JSON from text with leading prose" do
      text = "Here is the result:\n{\"status\": \"success\", \"info\": \"data\"}"
      result = WebToolMiddleware.extract_json_block(text)
      assert result == ~s({"status": "success", "info": "data"})
    end

    test "extracts JSON from text with trailing prose" do
      text = "{\"status\": \"success\"}\nThat's the answer."
      result = WebToolMiddleware.extract_json_block(text)
      assert result == ~s({"status": "success"})
    end

    test "extracts JSON from text with both leading and trailing prose" do
      text = "Let me provide the response:\n{\"status\": \"success\"}\nHope this helps!"
      result = WebToolMiddleware.extract_json_block(text)
      assert result == ~s({"status": "success"})
    end

    test "extracts multiline JSON" do
      text = """
      Here's the result:
      {
        "status": "success",
        "info": "data"
      }
      Done!
      """

      result = WebToolMiddleware.extract_json_block(text)
      assert String.contains?(result, "\"status\"")
      assert String.contains?(result, "\"success\"")
    end

    test "returns original text if no JSON found" do
      text = "No JSON here"
      result = WebToolMiddleware.extract_json_block(text)
      assert result == "No JSON here"
    end

    test "handles empty string" do
      result = WebToolMiddleware.extract_json_block("")
      assert result == ""
    end
  end

  describe "validate_success_fields/1" do
    test "validates correct success response" do
      data = %{
        "source_title" => "Example Title",
        "source_url" => "https://example.com",
        "information" => "Some useful information here"
      }

      assert WebToolMiddleware.validate_success_fields(data) == :ok
    end

    test "rejects empty source_title" do
      data = %{
        "source_title" => "",
        "source_url" => "https://example.com",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "source_title cannot be empty"
    end

    test "rejects whitespace-only source_title" do
      data = %{
        "source_title" => "   ",
        "source_url" => "https://example.com",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "source_title cannot be empty"
    end

    test "rejects empty source_url" do
      data = %{
        "source_title" => "Title",
        "source_url" => "",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "source_url cannot be empty"
    end

    test "rejects whitespace-only source_url" do
      data = %{
        "source_title" => "Title",
        "source_url" => "  ",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "source_url cannot be empty"
    end

    test "rejects empty information" do
      data = %{
        "source_title" => "Title",
        "source_url" => "https://example.com",
        "information" => ""
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "information cannot be empty"
    end

    test "rejects whitespace-only information" do
      data = %{
        "source_title" => "Title",
        "source_url" => "https://example.com",
        "information" => "  \n  "
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "information cannot be empty"
    end

    test "rejects missing source_title field" do
      data = %{
        "source_url" => "https://example.com",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects missing source_url field" do
      data = %{
        "source_title" => "Title",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects missing information field" do
      data = %{
        "source_title" => "Title",
        "source_url" => "https://example.com"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects non-string source_title" do
      data = %{
        "source_title" => 123,
        "source_url" => "https://example.com",
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects non-string source_url" do
      data = %{
        "source_title" => "Title",
        "source_url" => ["not", "a", "string"],
        "information" => "Some info"
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects non-string information" do
      data = %{
        "source_title" => "Title",
        "source_url" => "https://example.com",
        "information" => %{not: "a string"}
      }

      assert {:error, reason} = WebToolMiddleware.validate_success_fields(data)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects empty map" do
      assert {:error, reason} = WebToolMiddleware.validate_success_fields(%{})
      assert reason == "Missing required fields: source_title, source_url, information"
    end
  end

  describe "format_success_response/1" do
    test "formats valid response data" do
      data = %{
        "source_title" => "Elixir Programming Language",
        "source_url" => "https://elixir-lang.org",
        "information" =>
          "Elixir is a dynamic, functional language for building scalable applications."
      }

      result = WebToolMiddleware.format_success_response(data)

      assert is_binary(result)
      assert String.contains?(result, "Source: Elixir Programming Language")
      assert String.contains?(result, "URL: https://elixir-lang.org")
      assert String.contains?(result, "Elixir is a dynamic, functional language")
    end

    test "includes all provided information" do
      data = %{
        "source_title" => "Test Title",
        "source_url" => "https://test.com/page",
        "information" =>
          "First sentence. Second sentence with more details. Third sentence wrapping up."
      }

      result = WebToolMiddleware.format_success_response(data)

      assert String.contains?(result, "Test Title")
      assert String.contains?(result, "https://test.com/page")
      assert String.contains?(result, "First sentence")
      assert String.contains?(result, "Second sentence")
      assert String.contains?(result, "Third sentence")
    end

    test "handles information with newlines" do
      data = %{
        "source_title" => "Multi-line Info",
        "source_url" => "https://example.com",
        "information" => "Line 1\nLine 2\nLine 3"
      }

      result = WebToolMiddleware.format_success_response(data)

      assert String.contains?(result, "Line 1")
      assert String.contains?(result, "Line 2")
      assert String.contains?(result, "Line 3")
    end

    test "output format has source, URL, and information sections" do
      data = %{
        "source_title" => "Title",
        "source_url" => "https://url.com",
        "information" => "Info"
      }

      result = WebToolMiddleware.format_success_response(data)
      lines = String.split(result, "\n", trim: false)

      # Expected format:
      # Source: Title
      # URL: https://url.com
      # (blank line)
      # Info
      assert Enum.at(lines, 0) == "Source: Title"
      assert Enum.at(lines, 1) == "URL: https://url.com"
      assert Enum.at(lines, 2) == ""
      assert Enum.at(lines, 3) == "Info"
    end
  end

  describe "parse_and_validate_result/1" do
    test "parses and validates successful JSON response" do
      json_result =
        Jason.encode!(%{
          "status" => "success",
          "source_title" => "Elixir Documentation",
          "source_url" => "https://elixir-lang.org",
          "information" => "Elixir is a dynamic language.",
          "search_performed" => "Elixir programming"
        })

      assert {:ok, formatted} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert is_binary(formatted)
      assert String.contains?(formatted, "Elixir Documentation")
      assert String.contains?(formatted, "https://elixir-lang.org")
      assert String.contains?(formatted, "Elixir is a dynamic language")
    end

    test "extracts JSON from response with extra text" do
      result_with_text =
        "Here's the result:\n" <>
          Jason.encode!(%{
            "status" => "success",
            "source_title" => "Title",
            "source_url" => "https://example.com",
            "information" => "Info here"
          }) <> "\nDone!"

      assert {:ok, formatted} = WebToolMiddleware.parse_and_validate_result(result_with_text)
      assert String.contains?(formatted, "Title")
    end

    test "handles error status from subagent" do
      json_result =
        Jason.encode!(%{
          "status" => "error",
          "source_title" => "",
          "source_url" => "",
          "information" => "Search returned no results",
          "search_performed" => "nonexistent query"
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "Web lookup error: Search returned no results"
    end

    test "rejects response with missing status field" do
      json_result =
        Jason.encode!(%{
          "source_title" => "Title",
          "source_url" => "https://example.com",
          "information" => "Info"
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "Invalid response format: missing or invalid 'status' field"
    end

    test "rejects response with invalid status value" do
      json_result =
        Jason.encode!(%{
          "status" => "unknown",
          "source_title" => "Title",
          "source_url" => "https://example.com",
          "information" => "Info"
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "Invalid response format: missing or invalid 'status' field"
    end

    test "rejects success response with missing required fields" do
      json_result =
        Jason.encode!(%{
          "status" => "success",
          "source_title" => "Title"
          # Missing source_url and information
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "Missing required fields: source_title, source_url, information"
    end

    test "rejects success response with empty source_title" do
      json_result =
        Jason.encode!(%{
          "status" => "success",
          "source_title" => "",
          "source_url" => "https://example.com",
          "information" => "Some info"
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "source_title cannot be empty"
    end

    test "rejects success response with empty source_url" do
      json_result =
        Jason.encode!(%{
          "status" => "success",
          "source_title" => "Title",
          "source_url" => "",
          "information" => "Some info"
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "source_url cannot be empty"
    end

    test "rejects success response with empty information" do
      json_result =
        Jason.encode!(%{
          "status" => "success",
          "source_title" => "Title",
          "source_url" => "https://example.com",
          "information" => ""
        })

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert reason == "information cannot be empty"
    end

    test "rejects invalid JSON" do
      invalid_json = "{this is not valid json}"

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(invalid_json)
      assert String.starts_with?(reason, "Sub-agent returned invalid JSON:")
    end

    test "rejects non-JSON text" do
      plain_text = "This is just plain text without any JSON"

      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result(plain_text)
      assert String.starts_with?(reason, "Sub-agent returned invalid JSON:")
    end

    test "handles multiline formatted JSON" do
      json_result = """
      {
        "status": "success",
        "source_title": "Pretty Formatted",
        "source_url": "https://example.com",
        "information": "Formatted JSON with newlines",
        "search_performed": "test query"
      }
      """

      assert {:ok, formatted} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert String.contains?(formatted, "Pretty Formatted")
    end
  end

  describe "search_web_tool/0" do
    test "creates a valid Function struct" do
      tool = WebToolMiddleware.search_web_tool()

      assert is_struct(tool, LangChain.Function)
      assert tool.name == "search_web"
      assert is_binary(tool.description)
      assert is_map(tool.parameters_schema)
      assert tool.parameters_schema.required == ["query"]
      assert is_function(tool.function, 2)
    end

    test "tool function accepts args with query key" do
      tool = WebToolMiddleware.search_web_tool()
      # Note: This would require mocking AgentsDemo.WebTool.fetch_search_results/1
      # For now, we just verify the tool structure
      assert is_function(tool.function, 2)
    end
  end

  describe "fetch_page_tool/0" do
    test "creates a valid Function struct" do
      tool = WebToolMiddleware.fetch_page_tool()

      assert is_struct(tool, LangChain.Function)
      assert tool.name == "fetch_page"
      assert is_binary(tool.description)
      assert is_map(tool.parameters_schema)
      assert tool.parameters_schema.required == ["url"]
      assert is_function(tool.function, 2)
    end

    test "tool function accepts args with url key" do
      tool = WebToolMiddleware.fetch_page_tool()
      # Note: This would require mocking AgentsDemo.WebTool.fetch_webpage/1
      # For now, we just verify the tool structure
      assert is_function(tool.function, 2)
    end
  end

  describe "compiled subagent structure" do
    setup do
      model = ChatAnthropic.new!(%{model: "claude-3-haiku-20240307"})

      opts = [
        agent_id: "test-agent-123",
        model: model,
        middleware: []
      ]

      {:ok, config} = WebToolMiddleware.init(opts)
      {:ok, config: config}
    end

    test "compiled subagent has correct name", %{config: config} do
      assert config.compiled_subagent.name == "web-lookup"
    end

    test "compiled subagent has description", %{config: config} do
      assert is_binary(config.compiled_subagent.description)
      assert String.contains?(config.compiled_subagent.description, "Search web")
    end

    test "compiled subagent agent has correct tools", %{config: config} do
      agent = config.compiled_subagent.agent
      assert is_struct(agent, Agent)
      assert length(agent.tools) == 2

      tool_names = Enum.map(agent.tools, & &1.name)
      assert "search_web" in tool_names
      assert "fetch_page" in tool_names
    end

    test "compiled subagent agent has no middleware", %{config: config} do
      agent = config.compiled_subagent.agent
      assert agent.middleware == []
    end

    test "compiled subagent agent has base system prompt", %{config: config} do
      agent = config.compiled_subagent.agent
      assert is_binary(agent.base_system_prompt)
      assert String.contains?(agent.base_system_prompt, "web information retriever")
    end

    test "compiled subagent has empty initial_messages", %{config: config} do
      assert config.compiled_subagent.initial_messages == []
    end
  end

  describe "security considerations" do
    setup do
      model = ChatAnthropic.new!(%{model: "claude-3-haiku-20240307"})

      opts = [
        agent_id: "test-agent-123",
        model: model,
        middleware: []
      ]

      {:ok, config} = WebToolMiddleware.init(opts)
      {:ok, config: config}
    end

    test "subagent has no bash access - no middleware", %{config: config} do
      agent = config.compiled_subagent.agent
      assert agent.middleware == []

      # Verify no Bash or FileSystem middleware
      middleware_modules =
        Enum.map(agent.middleware, fn
          {mod, _opts} -> mod
          mod -> mod
        end)

      refute Sagents.Middleware.FileSystem in middleware_modules
    end

    test "subagent only has web-related tools", %{config: config} do
      agent = config.compiled_subagent.agent
      tool_names = Enum.map(agent.tools, & &1.name)

      # Only these two tools should be present
      assert tool_names == ["search_web", "fetch_page"]

      # Should not have any system tools
      refute "bash" in tool_names
      refute "read_file" in tool_names
      refute "write_file" in tool_names
    end

    test "query parameter validation prevents empty queries" do
      model = ChatAnthropic.new!(%{model: "claude-3-haiku-20240307"})

      opts = [
        agent_id: "test-agent-123",
        model: model,
        middleware: []
      ]

      {:ok, config} = WebToolMiddleware.init(opts)
      [tool] = WebToolMiddleware.tools(config)

      # Test empty query
      context = %{agent_id: "test", state: %{}}
      result = tool.function.(%{"query" => ""}, context)
      assert {:error, _} = result

      # Test whitespace-only query
      result = tool.function.(%{"query" => "   "}, context)
      assert {:error, _} = result

      # Test nil query
      result = tool.function.(%{}, context)
      assert {:error, _} = result
    end
  end

  describe "edge cases" do
    test "parse_and_validate_result handles empty string" do
      assert {:error, reason} = WebToolMiddleware.parse_and_validate_result("")
      assert String.contains?(reason, "invalid JSON")
    end

    test "parse_and_validate_result handles very long information" do
      long_info = String.duplicate("Long information text. ", 1000)

      json_result =
        Jason.encode!(%{
          "status" => "success",
          "source_title" => "Long Content",
          "source_url" => "https://example.com",
          "information" => long_info
        })

      assert {:ok, formatted} = WebToolMiddleware.parse_and_validate_result(json_result)
      assert String.contains?(formatted, "Long Content")
    end

    test "format_success_response handles special characters in information" do
      data = %{
        "source_title" => "Special <>&\" Chars",
        "source_url" => "https://example.com?a=1&b=2",
        "information" => "Info with 'quotes' and \"double quotes\" and <tags>"
      }

      result = WebToolMiddleware.format_success_response(data)
      assert String.contains?(result, "Special <>&\" Chars")
      assert String.contains?(result, "'quotes'")
      assert String.contains?(result, "\"double quotes\"")
    end

    test "validate_success_fields handles Unicode characters" do
      data = %{
        "source_title" => "Élixir Programming - 日本語",
        "source_url" => "https://example.com/🎉",
        "information" => "Unicode info: Ω ≈ ∞"
      }

      assert WebToolMiddleware.validate_success_fields(data) == :ok
    end
  end
end

defmodule AgentsDemo.WebToolTest do
  use ExUnit.Case, async: true
  doctest AgentsDemo.WebTool

  alias AgentsDemo.WebTool

  describe "fetch_webpage/1" do
    @tag :web_tool
    test "fetches a valid webpage and returns markdown" do
      result = WebTool.fetch_webpage("https://example.com")
      assert {:ok, content} = result
      assert is_binary(content)
      assert content != ""
    end
  end

  describe "fetch_search_results/1" do
    @tag :web_tool
    test "executes search and returns structured results" do
      {:ok, result} = WebTool.fetch_search_results("Elixir programming")

      assert result.status in [:success, :error]
      assert is_binary(result.message)
      assert is_list(result.links)

      if result.status == :success do
        assert length(result.links) <= 10

        Enum.each(result.links, fn link ->
          assert Map.has_key?(link, :title)
          assert Map.has_key?(link, :url)
          assert is_binary(link.title)
          assert is_binary(link.url)
          assert String.starts_with?(link.url, "http")
        end)
      end
    end

    test "returns error status for empty query after sanitization" do
      {:ok, result} = WebTool.fetch_search_results(";;;|||")

      assert result.status == :error
      assert result.message == "Query is empty after sanitization"
      assert result.links == []
    end

    test "returns error status for whitespace-only query" do
      {:ok, result} = WebTool.fetch_search_results("   ")

      assert result.status == :error
      assert result.message == "Query is empty after sanitization"
      assert result.links == []
    end
  end

  describe "sanitize_query/1" do
    test "removes shell injection characters like semicolons" do
      result = WebTool.sanitize_query("test; rm -rf /")
      assert result == "test rm -rf "
      refute String.contains?(result, ";")
      refute String.contains?(result, "/")
    end

    test "removes pipe characters" do
      result = WebTool.sanitize_query("test | cat /etc/passwd")
      refute String.contains?(result, "|")
      refute String.contains?(result, "/")
      assert String.contains?(result, "test")
    end

    test "removes backticks and command substitution syntax" do
      result = WebTool.sanitize_query("test `whoami` $(ls)")
      refute String.contains?(result, "`")
      refute String.contains?(result, "$")
      refute String.contains?(result, "(")
      refute String.contains?(result, ")")
      assert result == "test whoami ls"
    end

    test "removes ampersands and other shell operators" do
      result = WebTool.sanitize_query("test && echo 'bad' & bg")
      refute String.contains?(result, "&")
      assert result == "test  echo 'bad'  bg"
    end

    test "removes redirection operators" do
      result = WebTool.sanitize_query("test > output.txt < input.txt")
      refute String.contains?(result, ">")
      refute String.contains?(result, "<")
      assert result == "test  output.txt  input.txt"
    end

    test "allows safe characters: letters, numbers, spaces" do
      result = WebTool.sanitize_query("Hello World 123")
      assert result == "Hello World 123"
    end

    test "allows safe punctuation: comma, question, exclamation, hyphen, apostrophe, quote" do
      result = WebTool.sanitize_query("Hello, World! How are you? It's great - \"yes\"")
      assert result == "Hello, World! How are you? It's great - \"yes\""
      assert String.contains?(result, ",")
      assert String.contains?(result, "!")
      assert String.contains?(result, "?")
      assert String.contains?(result, "-")
      assert String.contains?(result, "'")
      assert String.contains?(result, "\"")
    end

    test "allows periods" do
      result = WebTool.sanitize_query("file.txt version 1.0")
      assert result == "file.txt version 1.0"
    end

    test "removes all dangerous characters in complex query" do
      result = WebTool.sanitize_query("test;rm -rf /&echo $PATH|cat>/tmp/x")
      refute String.contains?(result, ";")
      refute String.contains?(result, "&")
      refute String.contains?(result, "$")
      refute String.contains?(result, "|")
      refute String.contains?(result, ">")
      refute String.contains?(result, "/")
    end

    test "handles empty string" do
      result = WebTool.sanitize_query("")
      assert result == ""
    end

    test "handles string with only dangerous characters" do
      result = WebTool.sanitize_query(";;;;||||&&&&")
      assert result == ""
    end
  end

  describe "parse_search_results/1" do
    test "parses valid search output with multiple results" do
      output = """
      ---------------------------------------------------------------------------------------------------------------------------
      Elixir Programming Language ( https://elixir-lang.org )
      ---------------------------------------------------------------------------------------------------------------------------
      Getting Started with Elixir ( https://elixir-lang.org/getting-started )
      ---------------------------------------------------------------------------------------------------------------------------
      Elixir School - Learn Elixir ( https://elixirschool.com )
      ---------------------------------------------------------------------------------------------------------------------------
      """

      [result_1, result_2, result_3] = WebTool.parse_search_results(output)

      assert result_1 == %{
               title: "Elixir Programming Language",
               url: "https://elixir-lang.org"
             }

      assert result_2 == %{
               title: "Getting Started with Elixir",
               url: "https://elixir-lang.org/getting-started"
             }

      assert result_3 == %{
               title: "Elixir School - Learn Elixir",
               url: "https://elixirschool.com"
             }
    end

    test "does not return non-search result links" do
      output = """

      Learn More ( https://duckduckgo.com/duckduckgo-help-pages/search-privacy/ )

      You can hide this reminder in Search Settings ( /settings#appearance )

      -

      theknot.com

      Only include results for this site ( ?q=What%20to%20get%20my%20wife%20for%20our%20anniversary%3F%20site%3Awww.theknot.com ) Redo search without this site ( ?q=What%20to%20get%20my%20wife%20for%20our%20anniversary%3F%20-site%3Awww.theknot.com ) Block this site from all results NEW ( # )

      Share feedback about this site

      ( /?q=What%20to%20get%20my%20wife%20for%20our%20anniversary%3F+site:www.theknot.com&k1=-1&kc=-1&kl=en-us&ko=-1&kp=-1&kz=-1&t=h_ )

      The Knot

      https://www.theknot.com › content › anniversary-gifts-for-wife

      ( https://www.theknot.com/content/anniversary-gifts-for-wife )

      ---------------------------------------------------------------------------------------------------------------------------
      45 Anniversary Gift Ideas for Your Wife, Approved by Editors ( https://www.theknot.com/content/anniversary-gifts-for-wife )
      ---------------------------------------------------------------------------------------------------------------------------

      Feb 14, 2025 Use this list to buy the best *anniversary* present for your *wife*. Shop our greatest and most unique ideas, including jewelry and special experiences.

      """

      assert [result] = WebTool.parse_search_results(output)

      assert result == %{
               title: "45 Anniversary Gift Ideas for Your Wife, Approved by Editors",
               url: "https://www.theknot.com/content/anniversary-gifts-for-wife"
             }
    end

    test "returns empty list for output with no valid results" do
      output = """
      -------------------------------------------------
      No results found
      -------------------------------------------------
      """

      results = WebTool.parse_search_results(output)
      assert results == []
    end

    test "limits results to maximum of 10" do
      output = """
      ---------------------------------------------------------------------------------------------------------------------------
      Result 1 ( https://example.com/1 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 2 ( https://example.com/2 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 3 ( https://example.com/3 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 4 ( https://example.com/4 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 5 ( https://example.com/5 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 6 ( https://example.com/6 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 7 ( https://example.com/7 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 8 ( https://example.com/8 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 9 ( https://example.com/9 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 10 ( https://example.com/10 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 11 ( https://example.com/11 )
      ---------------------------------------------------------------------------------------------------------------------------
      Result 12 ( https://example.com/12 )
      ---------------------------------------------------------------------------------------------------------------------------
      """

      results = WebTool.parse_search_results(output)
      assert length(results) == 10
    end

    test "filters out non-matching lines within bracketed blocks" do
      output = """
      ---------------------------------------------------------------------------------------------------------------------------
      Valid Result ( https://example.com )
      This is not a valid line
      Another Valid Result ( https://example.com/2 )
      ---------------------------------------------------------------------------------------------------------------------------
      """

      results = WebTool.parse_search_results(output)
      assert length(results) == 2
      assert Enum.at(results, 0).url == "https://example.com"
      assert Enum.at(results, 1).url == "https://example.com/2"
    end

    test "handles empty output" do
      results = WebTool.parse_search_results("")
      assert results == []
    end
  end

  describe "parse_result_line/1" do
    test "parses valid line with title and URL" do
      line = "Elixir Programming Language ( https://elixir-lang.org )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Elixir Programming Language",
               url: "https://elixir-lang.org"
             }
    end

    test "parses line with URL containing path" do
      line = "Getting Started ( https://elixir-lang.org/getting-started )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Getting Started",
               url: "https://elixir-lang.org/getting-started"
             }
    end

    test "parses line with URL containing query parameters" do
      line = "Search Results ( https://example.com?q=test&page=1 )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Search Results",
               url: "https://example.com?q=test&page=1"
             }
    end

    test "parses line with URL containing fragment" do
      line = "Documentation Section ( https://example.com/docs#section )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Documentation Section",
               url: "https://example.com/docs#section"
             }
    end

    test "handles title with special characters and punctuation" do
      line = "Elixir, Phoenix & LiveView! ( https://example.com )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Elixir, Phoenix & LiveView!",
               url: "https://example.com"
             }
    end

    test "handles title with hyphen" do
      line = "Elixir - Modern Programming ( https://example.com )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Elixir - Modern Programming",
               url: "https://example.com"
             }
    end

    test "handles title with numbers" do
      line = "Top 10 Elixir Tips for 2024 ( https://example.com )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Top 10 Elixir Tips for 2024",
               url: "https://example.com"
             }
    end

    test "returns nil for line without proper format" do
      line = "This is not a valid result line"
      result = WebTool.parse_result_line(line)
      assert result == nil
    end

    test "returns nil for line with only dashes" do
      line = "---------------------------------------------"
      result = WebTool.parse_result_line(line)
      assert result == nil
    end

    test "returns nil for empty line" do
      result = WebTool.parse_result_line("")
      assert result == nil
    end

    test "returns nil for line with URL but no title" do
      line = "( https://example.com )"
      result = WebTool.parse_result_line(line)
      assert result == nil
    end

    test "parses HTTP URL (not just HTTPS)" do
      line = "Example Site ( http://example.com )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Example Site",
               url: "http://example.com"
             }
    end

    test "trims whitespace from title and URL within parentheses" do
      line = "Elixir Lang   (   https://elixir-lang.org   )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Elixir Lang",
               url: "https://elixir-lang.org"
             }
    end

    test "trims leading whitespace from title" do
      # The regex matches and String.trim handles leading/trailing whitespace
      line = "  Elixir Lang ( https://elixir-lang.org )"
      result = WebTool.parse_result_line(line)

      assert result == %{
               title: "Elixir Lang",
               url: "https://elixir-lang.org"
             }
    end
  end

  describe "is_separator_line?/1" do
    test "identifies lines with 10+ consecutive dashes" do
      assert WebTool.is_separator_line?("----------") == true
      assert WebTool.is_separator_line?("---------------------------------------------") == true

      assert WebTool.is_separator_line?(
               "---------------------------------------------------------------------------------------------------------------------------"
             ) == true
    end

    test "rejects lines with fewer than 10 consecutive dashes" do
      assert WebTool.is_separator_line?("---------") == false
      assert WebTool.is_separator_line?("-----") == false
      assert WebTool.is_separator_line?("-") == false
    end

    test "identifies lines with dashes and other characters" do
      # As long as there are 10+ consecutive dashes somewhere in the line
      assert WebTool.is_separator_line?("  ----------  ") == true
      assert WebTool.is_separator_line?("abc----------xyz") == true
    end

    test "rejects lines without 10 consecutive dashes" do
      assert WebTool.is_separator_line?("- - - - - - - - - -") == false
      assert WebTool.is_separator_line?("Valid Line") == false
      assert WebTool.is_separator_line?("") == false
    end
  end

  describe "extract_bracketed_blocks/1" do
    test "extracts lines between separator lines and filters by pattern" do
      lines = [
        "----------",
        "Result 1 ( https://example.com/1 )",
        "----------",
        "----------",
        "Result 2 ( https://example.com/2 )",
        "----------"
      ]

      result = WebTool.extract_bracketed_blocks(lines)

      assert result == [
               "Result 1 ( https://example.com/1 )",
               "Result 2 ( https://example.com/2 )"
             ]
    end

    test "filters out lines that don't match pattern within blocks" do
      lines = [
        "----------",
        "Result 1 ( https://example.com/1 )",
        "Some other text",
        "Result 2 ( https://example.com/2 )",
        "----------"
      ]

      result = WebTool.extract_bracketed_blocks(lines)

      assert result == [
               "Result 1 ( https://example.com/1 )",
               "Result 2 ( https://example.com/2 )"
             ]
    end

    test "handles multiple lines between separators" do
      lines = [
        "---------------------------------------------------------------------------------------------------------------------------",
        "Line 1",
        "Result ( https://example.com )",
        "Line 3",
        "---------------------------------------------------------------------------------------------------------------------------"
      ]

      result = WebTool.extract_bracketed_blocks(lines)
      # Should only include the line that matches the pattern
      assert result == ["Result ( https://example.com )"]
    end

    test "handles no content between separators" do
      lines = [
        "----------",
        "----------",
        "----------"
      ]

      result = WebTool.extract_bracketed_blocks(lines)
      assert result == []
    end

    test "handles empty list" do
      result = WebTool.extract_bracketed_blocks([])
      assert result == []
    end

    test "handles list with no separators" do
      lines = ["Line 1", "Line 2", "Line 3"]
      result = WebTool.extract_bracketed_blocks(lines)
      assert result == []
    end

    test "handles list with only one separator" do
      lines = [
        "Line 1",
        "----------",
        "Line 2"
      ]

      result = WebTool.extract_bracketed_blocks(lines)
      assert result == []
    end
  end
end

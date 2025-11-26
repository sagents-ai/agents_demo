defmodule AgentsDemo.WebTool do
  @moduledoc """
  Provides web interaction tools for agents.

  This module offers functions to:
  - Fetch webpages as markdown using an external Go binary
  - Search DuckDuckGo and extract structured results

  Both functions interface with the `web-linux-amd64` Go binary located
  in the project's priv directory.
  """

  @duckduckgo_url "https://duckduckgo.com?kl=en-us&kp=-1&kz=-1&kc=-1&ko=-1&k1=-1"
  @max_results 10

  defp web_binary_path do
    Application.app_dir(:agents_demo, "priv/web-linux-amd64")
  end

  @doc """
  Fetches a webpage and returns its content as markdown.

  ## Parameters

    * `url` - The URL to fetch

  ## Returns

    * `{:ok, markdown}` - On success, returns the page content as markdown
    * `{:error, reason}` - On failure, returns the error reason

  ## Examples

      AgentsDemo.WebTool.fetch_webpage("https://example.com")
      # => {:ok, "# Example Domain\\n\\nThis domain is..."}

      AgentsDemo.WebTool.fetch_webpage("invalid-url")
      # => {:error, "Failed to fetch: ..."}
  """
  @spec fetch_webpage(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_webpage(url) when is_binary(url) do
    case System.cmd(web_binary_path(), [url], stderr_to_stdout: true) do
      {markdown, 0} ->
        {:ok, markdown}

      {error, _code} ->
        {:error, "Failed to fetch: #{error}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Binary execution failed: #{Exception.message(e)}"}
  end

  @doc """
  Searches DuckDuckGo and returns structured results.

  This function sanitizes the query to prevent shell injection attacks,
  executes a search via the Go binary, and parses the results into a
  structured format.

  ## Parameters

    * `query` - The search query string

  ## Returns

    * `{:ok, results}` - On success, returns a map with:
      * `:status` - `:success`
      * `:message` - Descriptive message
      * `:links` - List of maps with `:title` and `:url` keys (up to 6 results)
    * `{:error, reason}` - On failure, returns error reason

  ## Query Sanitization

  The query is sanitized to allow only safe characters:
  - Letters (a-z, A-Z)
  - Numbers (0-9)
  - Spaces
  - Common punctuation: . , ? ! - ' "

  Any other characters are removed.

  ## Examples

      AgentsDemo.WebTool.fetch_search_results("Elixir programming")
      # => {:ok, %{
      #      status: :success,
      #      message: "Found 10 results for query: 'Elixir programming'",
      #      links: [
      #        %{title: "Elixir Programming Language", url: "https://elixir-lang.org"},
      #        # ... more results
      #      ]
      #    }}

      AgentsDemo.WebTool.fetch_search_results("test; rm -rf /")
      # => {:ok, %{
      #      status: :success,
      #      message: "Found N results for query: 'test rm  rf '",
      #      links: [...]
      #    }}
  """
  @spec fetch_search_results(String.t()) ::
          {:ok,
           %{
             status: :success | :error,
             message: String.t(),
             links: [%{title: String.t(), url: String.t()}]
           }}
          | {:error, String.t()}
  def fetch_search_results(query) when is_binary(query) do
    sanitized_query = sanitize_query(query)

    if String.trim(sanitized_query) == "" do
      {:ok,
       %{
         status: :error,
         message: "Query is empty after sanitization",
         links: []
       }}
    else
      execute_search(sanitized_query)
    end
  end

  # Semi-private functions (public for testing with @doc false)

  @doc false
  def sanitize_query(query) do
    # Whitelist approach: only allow safe characters
    # Letters, numbers, spaces, and common punctuation
    Regex.replace(~r/[^a-zA-Z0-9\s\.\,\?\!\-\'\"]/u, query, "")
  end

  defp execute_search(query) do
    args = [
      @duckduckgo_url,
      "--form",
      "searchbox_homepage",
      "--input",
      "q",
      "--value",
      query
    ]

    case System.cmd(web_binary_path(), args, stderr_to_stdout: true) do
      {output, 0} ->
        links = parse_search_results(output)

        {:ok,
         %{
           status: :success,
           message: "Found #{length(links)} results for query: '#{query}'",
           links: links
         }}

      {error, _code} ->
        {:ok,
         %{
           status: :error,
           message: "Search failed: #{error}",
           links: []
         }}
    end
  rescue
    e in ErlangError ->
      {:ok,
       %{
         status: :error,
         message: "Binary execution failed: #{Exception.message(e)}",
         links: []
       }}
  end

  @doc false
  def parse_search_results(output) do
    # Split output into lines
    lines = String.split(output, "\n")

    # Find blocks delimited by separator lines (lines with many dashes)
    # Search results are bracketed between two separator lines
    lines
    |> extract_bracketed_blocks()
    |> Enum.map(&parse_result_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_results)
  end

  @doc false
  def extract_bracketed_blocks(lines) do
    # Find all separator line indices (lines with 10+ consecutive dashes)
    separator_indices =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _idx} -> is_separator_line?(line) end)
      |> Enum.map(fn {_line, idx} -> idx end)

    # Extract content between consecutive separator lines
    separator_indices
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [start_idx, end_idx] ->
      # Get lines between the separators
      if end_idx <= start_idx + 1 do
        # No content between separators or adjacent separators
        []
      else
        # Extract lines between separators and filter for those matching the pattern
        Enum.slice(lines, (start_idx + 1)..(end_idx - 1))
        |> Enum.filter(fn line ->
          String.trim(line) != "" && parse_result_line(line) != nil
        end)
      end
    end)
  end

  @doc false
  def is_separator_line?(line) do
    # A separator line has at least 10 consecutive dashes
    # It may have spaces and other dashes, but we need a run of dashes
    String.contains?(line, String.duplicate("-", 10))
  end

  @doc false
  def parse_result_line(line) do
    # Match pattern: "Title ( URL )"
    # The title can contain any characters, and URL should be a valid HTTP(S) URL
    case Regex.run(~r/^(.+?)\s+\(\s+(https?:\/\/[^\s\)]+)\s*\)$/u, line) do
      [_full, title, url] ->
        %{
          title: String.trim(title),
          url: String.trim(url)
        }

      nil ->
        nil
    end
  end
end

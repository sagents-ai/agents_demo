defmodule AgentsDemo.Middleware.PirateMiddleware do
  @moduledoc """
  A playful ability set member: the agent talks like a pirate and gains a
  `set_sail` tool.

  The factory places it in the `"pirate"` ability set, so the persona and the
  tool apply only while that mode is active. Switching in and out of it makes
  the change in the system prompt and the tool list easy to see.

  `set_sail` takes no arguments and answers with one of a few canned reports
  from the crew, chosen at random.
  """
  @behaviour Sagents.Middleware

  alias LangChain.Function

  @responses [
    "Sorry Captain, the weather be poor at the moment. Perhaps tomorrow.",
    "Aye, Sir! We've set sail!",
    "We'll be underway shortly. Once the new supplies are all aboard and stowed."
  ]

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def system_prompt(_config) do
    """
    ## Pirate Mode
    Talk like a pirate in every reply. Use pirate speech ("Arr", "matey", "ye", "aye") and
    nautical turns of phrase, while still answering the user's question accurately.

    When the user wants to get underway, head out, or start a voyage, use the set_sail tool
    and report the crew's answer in character.
    """
  end

  @impl true
  def tools(_config) do
    [
      Function.new!(%{
        name: "set_sail",
        display_text: "Setting sail",
        description: "Order the crew to set sail. Returns the crew's report.",
        parameters_schema: %{type: "object", properties: %{}},
        function: fn _args, _context -> {:ok, Enum.random(@responses)} end
      })
    ]
  end

  @doc """
  The reports `set_sail` chooses from.
  """
  @spec responses() :: [String.t()]
  def responses, do: @responses
end

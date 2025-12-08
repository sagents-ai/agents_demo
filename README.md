# AgentsDemo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Web search tool

The web search tool demonstrates both how to perform a web search tool using your own hardware instead of a service and how to create a custom middleware.

Uses DuckDuckGo with some personal-use-only flags set to clean up the results
- https://duckduckgo.com/duckduckgo-help-pages/settings/params

Uses Chris McCord's "web" project
- https://github.com/chrismccord/web
- Uses a local embedded Firefox to scrape pages

Step 0:
- Download the appropriate binary for your platform from [web project page](https://github.com/chrismccord/web).
  - web-darwin-amd64
  - web-darwin-arm64
  - web-linux-amd64
- Rename the downloaded binary to `web`
- Place the binary in `priv/`

Step 1:
- Data extraction of the top results from a search. Returns JSON information.

Step 2:
- Main agent uses links to spawn separate task to fetch the provided link
- Sub-Agent fetches the page and performs document analysis for how the web-page answers the original question
- Sub-Agents return the names of the created analysis documents

```
./web "https://duckduckgo.com?kl=en-us&kp=-1&kz=-1&kc=-1&ko=-1&k1=-1" --form "searchbox_homepage" --input "q" --value "What is the tallest building in the world?"
```

Reading a page:
```
./web "https://www.wionews.com/photos/10-tallest-buildings-in-the-world-9016954"
```

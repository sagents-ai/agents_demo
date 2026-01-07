# FileSystemSupervisor will be started by the application supervision tree

# Set up Mimic for mocking in tests
Mimic.copy(LangChain.ChatModels.ChatAnthropic)
Mimic.copy(LangChain.ChatModels.ChatOpenAI)

# ExUnit.start(exclude: [:web_tool], capture_log: true)
ExUnit.start(exclude: [:web_tool], capture_log: false)

Ecto.Adapters.SQL.Sandbox.mode(AgentsDemo.Repo, :manual)

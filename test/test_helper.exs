# FileSystemSupervisor will be started by the application supervision tree
ExUnit.start(exclude: [:web_tool], capture_log: true)

Ecto.Adapters.SQL.Sandbox.mode(AgentsDemo.Repo, :manual)

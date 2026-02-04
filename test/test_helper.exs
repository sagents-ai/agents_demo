# FileSystemSupervisor will be started by the application supervision tree

# Set up Mimic for mocking in tests
Mimic.copy(LangChain.ChatModels.ChatAnthropic)
Mimic.copy(LangChain.ChatModels.ChatOpenAI)

ExUnit.start(exclude: [:web_tool], capture_log: true)
# ExUnit.start(exclude: [:web_tool], capture_log: false)

# Clean up test filesystem after entire test suite completes
# This prevents race conditions with async tests sharing the same temp directory
ExUnit.after_suite(fn _results ->
  partition = System.get_env("MIX_TEST_PARTITION", "")
  test_dir = Path.join([System.tmp_dir!(), "agents_demo_test#{partition}"])

  if File.exists?(test_dir) do
    File.rm_rf!(test_dir)
  end
end)

Ecto.Adapters.SQL.Sandbox.mode(AgentsDemo.Repo, :manual)

import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :agents_demo, AgentsDemo.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "agents_demo_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :agents_demo, AgentsDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "1ucpgggKD06EdyuAUcqtPYRrzXO4o+RZ8J+S/n9nfFo12rKiJW1nH06RIzmi8BQj",
  server: false

# In test we don't send emails
config :agents_demo, AgentsDemo.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :info

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Configure LangChain for testing with dummy AWS credentials
config :langchain,
  aws_access_key_id: System.get_env("AWS_ACCESS_KEY_ID", "test_key_id"),
  aws_secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", "test_secret_key"),
  aws_region: System.get_env("AWS_REGION", "us-west-1")

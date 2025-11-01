defmodule AgentsDemo.Repo do
  use Ecto.Repo,
    otp_app: :agents_demo,
    adapter: Ecto.Adapters.Postgres
end

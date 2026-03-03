defmodule AgentsDemo.Repo.Migrations.AddFirstNameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :first_name, :string
    end
  end
end

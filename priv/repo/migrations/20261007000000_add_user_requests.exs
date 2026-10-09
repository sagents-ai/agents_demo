defmodule AgentsDemo.Repo.Migrations.AddUserRequests do
  @moduledoc """
  Adds user request tracking to an existing install: the user request number and
  final-answer flag on display rows, and a ledger with one row per finished
  user request. Rows written before this carry no user request number and are
  not backfilled.
  """

  use Ecto.Migration

  def change do
    alter table(:sagents_display_messages) do
      add :user_request_seq, :integer
      add :user_request_final, :boolean, default: false, null: false
    end

    create index(:sagents_display_messages, [:conversation_id, :user_request_seq])

    create table(:sagents_user_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:sagents_conversations, on_delete: :delete_all, type: :binary_id),
          null: false

      add :seq, :integer, null: false
      add :status, :string, null: false
      add :completed_at, :utc_datetime_usec, null: false
      add :assistant_message_count, :integer, default: 0, null: false
      add :tool_calls, :map, default: %{}
      add :token_usage, :map, default: %{}
      add :classification, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sagents_user_requests, [:conversation_id, :seq])
  end
end

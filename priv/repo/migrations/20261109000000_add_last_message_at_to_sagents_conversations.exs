defmodule AgentsDemo.Repo.Migrations.AddLastMessageAtToSagentsConversations do
  @moduledoc """
  Adds `last_message_at` to conversations: the time of the latest display
  message, which the "recent first" listing sorts by. Existing rows take their
  latest message's `inserted_at`, or the conversation's own `inserted_at` when
  it has no messages, so the column can be NOT NULL.

  The owner index becomes `[:user_id, :last_message_at]`, which serves both the
  listing and owner-only lookups. Nothing queries by `updated_at`, so its index
  is dropped.
  """

  use Ecto.Migration

  def up do
    alter table(:sagents_conversations) do
      add :last_message_at, :utc_datetime_usec
    end

    flush()

    execute("""
    UPDATE sagents_conversations AS c
    SET last_message_at = COALESCE(
      (SELECT max(m.inserted_at)
       FROM sagents_display_messages AS m
       WHERE m.conversation_id = c.id),
      c.inserted_at
    )
    """)

    alter table(:sagents_conversations) do
      modify :last_message_at, :utc_datetime_usec, null: false
    end

    drop index(:sagents_conversations, [:user_id])
    drop index(:sagents_conversations, [:updated_at])
    create index(:sagents_conversations, [:user_id, :last_message_at])
  end

  def down do
    drop index(:sagents_conversations, [:user_id, :last_message_at])
    create index(:sagents_conversations, [:updated_at])
    create index(:sagents_conversations, [:user_id])

    alter table(:sagents_conversations) do
      remove :last_message_at
    end
  end
end

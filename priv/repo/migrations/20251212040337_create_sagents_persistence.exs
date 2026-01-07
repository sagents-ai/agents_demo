defmodule AgentsDemo.Repo.Migrations.CreateSagentsPersistence do
  use Ecto.Migration

  def change do
    # Conversations table
    create table(:sagents_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string
      add :version, :integer, default: 1, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sagents_conversations, [:user_id])
    create index(:sagents_conversations, [:updated_at])

    # Agent states table (one per conversation)
    create table(:sagents_agent_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, references(:sagents_conversations, on_delete: :delete_all, type: :binary_id), null: false
      add :state_data, :map, null: false
      add :version, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sagents_agent_states, [:conversation_id])

    # Display messages table (multi-content type support)
    create table(:sagents_display_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, references(:sagents_conversations, on_delete: :delete_all, type: :binary_id), null: false
      add :message_type, :string, null: false  # "user", "assistant", "tool", "system"
      add :content, :map, null: false  # JSONB storage for flexible content
      add :content_type, :string, null: false, default: "text"  # Content type for rendering
      add :sequence, :integer, default: 0, null: false  # Message-local ordering (0-based within same timestamp)
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sagents_display_messages, [:conversation_id, :inserted_at, :sequence])
    create index(:sagents_display_messages, [:content_type])  # For filtering by content type
  end
end

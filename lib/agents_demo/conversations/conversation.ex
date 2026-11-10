defmodule AgentsDemo.Conversations.Conversation do
  @moduledoc """
  Schema for conversations.

  A conversation represents a series of interactions between a user and an AI agent.

  `last_message_at` is the time of the conversation's latest display message,
  or its creation time when it has none. It is what "most recent first"
  listings sort by. The system sets it; it is never cast from attrs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias __MODULE__
  alias AgentsDemo.Conversations.AgentState
  alias AgentsDemo.Conversations.DisplayMessage

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sagents_conversations" do
    belongs_to :user, AgentsDemo.Accounts.User, foreign_key: :user_id, type: :id
    has_one :agent_state, AgentState
    has_many :display_messages, DisplayMessage

    field :title, :string
    field :version, :integer, default: 1
    field :metadata, :map, default: %{}

    # When the latest message was added; the "recent" sort. Kept apart from
    # `updated_at`, which messages never touch (they live in their own table)
    # and which renaming or other row edits move.
    field :last_message_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(owner_id, attrs) do
    %Conversation{}
    |> cast(attrs, [:title, :version, :metadata])
    |> put_change(:user_id, owner_id)
    |> put_change(:last_message_at, DateTime.utc_now())
    |> common_validations()
  end

  @doc false
  def changeset(%Conversation{} = conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :version, :metadata])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_required([:user_id])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:user_id)
  end
end

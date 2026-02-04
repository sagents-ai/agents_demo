defmodule AgentsDemo.Agents.DemoSetup do
  @moduledoc """
  Demo-specific setup and configuration.

  This module contains demo-specific behavior that you would NOT want in production:
  - File seeding for new users
  - Default disk persistence configuration
  - Demo content management

  **For production**: Remove this module and configure persistence/seeding
  according to your application's needs.
  """

  alias Sagents.FileSystem
  alias Sagents.FileSystem.FileSystemConfig
  alias Sagents.FileSystem.Persistence.Disk

  require Logger

  @doc """
  Ensure a user's filesystem is running.

  This function is idempotent - calling it multiple times for the same user
  will return the same filesystem scope without error.

  For new users (directory doesn't exist), copies template files from
  `priv/new_user_template/` to provide helpful starter content.

  Files are stored in:
  - **Development/Production**: `user_files/{user_id}/memories/` at project root
  - **Test**: `/tmp/agents_demo_test{partition}/user_files/{user_id}/memories/` (auto-cleaned)

  **Production Note**: In production, you might want:
  - Database-backed persistence
  - Cloud storage (S3, etc.)
  - No persistence (ephemeral conversations)
  - Per-organization or per-workspace storage

  ## Examples

      {:ok, scope} = DemoSetup.ensure_user_filesystem(user_id)
      # => {:ok, {:user, 123}}

      # Use scope when starting conversations
      {:ok, session} = Coordinator.start_conversation_session(conv_id, filesystem_scope: scope)
  """
  def ensure_user_filesystem(user_id) do
    # Setup directory structure and get storage path
    storage_path = setup_user_directory(user_id)

    # Create filesystem config with scope_key
    scope_key = {:user, user_id}

    {:ok, fs_config} =
      FileSystemConfig.new(%{
        scope_key: scope_key,
        base_directory: "Memories",
        persistence_module: Disk,
        debounce_ms: 5000,
        storage_opts: [path: storage_path]
      })

    # Start the filesystem (idempotent) with PubSub for real-time updates
    pubsub_config = {Phoenix.PubSub, AgentsDemo.PubSub}

    case FileSystem.ensure_filesystem(scope_key, [fs_config], pubsub: pubsub_config) do
      {:ok, _pid} ->
        Logger.info("User filesystem ready for user #{user_id} (scope: #{inspect(scope_key)})")
        {:ok, scope_key}

      {:error, :supervisor_not_ready} = error ->
        # This is expected in async tests where FileSystemSupervisor isn't available
        Logger.debug(
          "FileSystemSupervisor not available for user #{user_id} - filesystem will not be available"
        )

        error

      {:error, reason} = error ->
        # Actual errors should be logged at error level
        Logger.error("Failed to start filesystem for user #{user_id}: #{inspect(reason)}")
        error
    end
  end

  # Private helper to get storage base path based on environment
  defp get_storage_base_path do
    case Mix.env() do
      :test ->
        # Use system temp directory for test isolation
        # Support test partitioning for parallel execution
        partition = System.get_env("MIX_TEST_PARTITION", "")
        Path.join([System.tmp_dir!(), "agents_demo_test#{partition}", "user_files"])

      _ ->
        # Development and production use project root
        Path.join(File.cwd!(), "user_files")
    end
  end

  # Private helper to setup user directory and return storage path
  defp setup_user_directory(user_id) do
    # Use environment-appropriate base path
    base_path = get_storage_base_path()
    storage_path = Path.join([base_path, to_string(user_id), "memories"])

    # Check if this is a new user (directory doesn't exist)
    is_new_user = not File.exists?(storage_path)

    if is_new_user do
      # New user - create directory and copy template files
      File.mkdir_p!(storage_path)

      priv_dir = :code.priv_dir(:agents_demo) |> to_string()
      template_path = Path.join(priv_dir, "new_user_template")

      if File.exists?(template_path) and not empty_directory?(storage_path) == false do
        # Copy contents of template directory (not the directory itself)
        copy_directory_contents(template_path, storage_path)
        Logger.info("Initialized filesystem for new user #{user_id} from template")
      else
        Logger.debug("Created empty filesystem directory for user #{user_id}")
      end
    else
      # Returning user - leave their files as-is
      Logger.debug("Using existing filesystem for user #{user_id}")
    end

    storage_path
  end

  # Check if directory is empty
  defp empty_directory?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      {:ok, _} -> false
      {:error, _} -> true
    end
  end

  # Private helper to copy directory contents (not the directory itself)
  defp copy_directory_contents(source_dir, dest_dir) do
    {:ok, entries} = File.ls(source_dir)

    Enum.each(entries, fn entry ->
      source_path = Path.join(source_dir, entry)
      dest_path = Path.join(dest_dir, entry)

      if File.dir?(source_path) do
        # Recursively copy subdirectory
        File.mkdir_p!(dest_path)
        copy_directory_contents(source_path, dest_path)
      else
        # Copy file
        File.cp!(source_path, dest_path)
      end
    end)
  end
end

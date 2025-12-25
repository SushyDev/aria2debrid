defmodule ProcessingQueue.Validators.PathValidator do
  @moduledoc """
  Validates that torrent files are accessible on the filesystem.

  Verifies that the expected save path exists and contains the
  torrent's files. This is used when rclone mounts Real-Debrid
  storage locally.

  ## Usage

      case PathValidator.validate(torrent) do
        :ok -> # Paths are accessible
        {:skip, reason} -> # Validation skipped (disabled)
        {:error, reason} -> # Paths not accessible
      end

  ## Retry Behavior

  Path validation retries indefinitely with configurable delay
  (default 10 seconds) since rclone mounts may take time to sync.
  """

  require Logger

  alias ProcessingQueue.Torrent

  @doc """
  Validates that torrent paths exist on filesystem.

  ## Parameters
    - `torrent` - Torrent struct with save_path

  ## Returns
    - `:ok` - Paths exist and are accessible
    - `{:skip, reason}` - Validation skipped (disabled by config)
    - `{:error, reason}` - Paths not accessible
  """
  @spec validate(Torrent.t()) :: :ok | {:skip, String.t()} | {:error, term()}
  def validate(%Torrent{} = torrent) do
    if Aria2Debrid.Config.validate_paths?() do
      do_validate(torrent)
    else
      Logger.debug("Path validation disabled by config")
      {:skip, "Path validation disabled"}
    end
  end

  @doc """
  Validates that torrent paths exist with retries.

  Retries indefinitely with configurable delay between attempts.
  This is appropriate because rclone mounts may take variable time to sync.

  ## Parameters
    - `torrent` - Torrent struct with save_path
    - `opts` - Options:
      - `:delay_ms` - Delay between retries in ms (default from config)

  ## Returns
    - `:ok` - Paths exist
    - `{:skip, reason}` - Validation disabled
  """
  @spec validate_with_retry(Torrent.t(), keyword()) :: :ok | {:skip, String.t()}
  def validate_with_retry(%Torrent{} = torrent, opts \\ []) do
    if not Aria2Debrid.Config.validate_paths?() do
      {:skip, "Path validation disabled"}
    else
      delay_ms = Keyword.get(opts, :delay_ms, Aria2Debrid.Config.path_validation_delay())
      do_validate_with_retry(torrent, delay_ms)
    end
  end

  @doc """
  Gets the expected save path for a torrent.

  Constructs the full path where the torrent's files should be located.
  """
  @spec get_save_path(Torrent.t()) :: String.t()
  def get_save_path(%Torrent{save_path: save_path}) when is_binary(save_path) do
    save_path
  end

  def get_save_path(%Torrent{name: name}) when is_binary(name) do
    Path.join(Aria2Debrid.Config.save_path(), name)
  end

  def get_save_path(_) do
    Aria2Debrid.Config.save_path()
  end

  @doc """
  Checks if a path exists on the filesystem.
  """
  @spec path_exists?(String.t()) :: boolean()
  def path_exists?(path) when is_binary(path) do
    File.exists?(path)
  end

  def path_exists?(_), do: false

  @doc """
  Checks if a directory exists and contains files.
  """
  @spec directory_has_files?(String.t()) :: boolean()
  def directory_has_files?(path) when is_binary(path) do
    case File.ls(path) do
      {:ok, entries} -> length(entries) > 0
      {:error, _} -> false
    end
  end

  def directory_has_files?(_), do: false

  # Private functions

  defp do_validate(%Torrent{hash: hash} = torrent) do
    save_path = get_save_path(torrent)

    cond do
      save_path == nil or save_path == "" ->
        Logger.warning("[#{hash}] No save path configured")
        {:error, {:missing_path, "No save path configured"}}

      not path_exists?(save_path) ->
        Logger.debug("[#{hash}] Path does not exist: #{save_path}")
        {:error, {:path_not_found, save_path}}

      File.dir?(save_path) and not directory_has_files?(save_path) ->
        Logger.debug("[#{hash}] Directory exists but is empty: #{save_path}")
        {:error, {:empty_directory, save_path}}

      true ->
        Logger.info("[#{hash}] Path validation passed: #{save_path}")
        :ok
    end
  end

  defp do_validate_with_retry(torrent, delay_ms) do
    case do_validate(torrent) do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(delay_ms)
        do_validate_with_retry(torrent, delay_ms)
    end
  end
end

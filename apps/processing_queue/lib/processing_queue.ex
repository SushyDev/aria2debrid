defmodule ProcessingQueue do
  @moduledoc """
  Async torrent processing queue for DebridDriveEx.

  Manages torrent lifecycle through a state machine:
  PENDING → ADDING_RD → WAITING_METADATA → SELECTING_FILES → REFRESHING_INFO →
  FETCHING_QUEUE → VALIDATING_COUNT → VALIDATING_MEDIA → WAITING_DOWNLOAD → 
  VALIDATING_PATH → SUCCESS/FAILED

  ## Usage

      # Add a torrent by magnet link
      {:ok, hash} = ProcessingQueue.add_magnet("magnet:?xt=urn:btih:...")

      # Get torrent status
      {:ok, torrent} = ProcessingQueue.get_torrent(hash)

      # List all torrents
      torrents = ProcessingQueue.list_torrents()
  """

  alias ProcessingQueue.{Manager, Torrent}

  @doc """
  Adds a torrent by magnet link.

  Returns `{:ok, hash}` on success or `{:error, reason}` on failure.
  """
  @spec add_magnet(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_magnet(magnet, opts \\ []) do
    Manager.add_magnet(magnet, opts)
  end

  @doc """
  Adds a torrent by torrent file binary data.

  Returns `{:ok, hash}` on success or `{:error, reason}` on failure.

  The torrent file binary is parsed to extract the infohash, then uploaded to Real-Debrid.
  """
  @spec add_torrent_file(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_torrent_file(torrent_data, opts \\ []) when is_binary(torrent_data) do
    Manager.add_torrent_file(torrent_data, opts)
  end

  @doc """
  Gets a torrent by its infohash.
  """
  @spec get_torrent(String.t()) :: {:ok, Torrent.t()} | {:error, :not_found}
  def get_torrent(hash) do
    Manager.get_torrent(hash)
  end

  @doc """
  Lists all torrents in the queue.
  """
  @spec list_torrents() :: [Torrent.t()]
  def list_torrents do
    Manager.list_torrents()
  end

  @doc """
  Removes a torrent from the queue.
  """
  @spec remove_torrent(String.t()) :: :ok | {:error, term()}
  def remove_torrent(hash) do
    Manager.remove_torrent(hash)
  end

  @doc """
  Pauses a torrent (marks as failed).
  """
  @spec pause_torrent(String.t()) :: :ok | {:error, term()}
  def pause_torrent(hash) do
    Manager.pause_torrent(hash)
  end

  @doc """
  Resumes a failed torrent.
  """
  @spec resume_torrent(String.t()) :: :ok | {:error, term()}
  def resume_torrent(hash) do
    Manager.resume_torrent(hash)
  end

  @doc """
  Gets the aria2-compatible status for a torrent.

  Status mapping to aria2 status values:
  - `:success` -> "complete" (download completed successfully)
  - `:failed` with `:validation` failure -> "error" (triggers Sonarr/Radarr re-search)
  - `:failed` with `:permanent` failure -> "error" (permanent failure)
  - `:waiting_metadata`, `:waiting_download` -> "active" (actively downloading)
  - Other states -> "waiting" (queued or preparing)
  """
  @spec get_aria2_status(Torrent.t()) :: String.t()
  def get_aria2_status(%Torrent{state: :success}), do: "complete"

  def get_aria2_status(%Torrent{state: :failed}), do: "error"

  def get_aria2_status(%Torrent{state: state})
      when state in [:waiting_metadata, :waiting_download] do
    "active"
  end

  def get_aria2_status(%Torrent{}), do: "waiting"
end

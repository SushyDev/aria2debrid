defmodule ProcessingQueue.Torrent do
  @moduledoc """
  Represents a torrent being processed through the queue.
  """

  @type state ::
          :pending
          | :fetching_queue
          | :adding_rd
          | :waiting_metadata
          | :selecting_files
          | :refreshing_info
          | :validating_count
          | :validating_media
          | :waiting_download
          | :validating_path
          | :success
          | :failed

  @type failure_type :: :validation | :permanent | :warning | nil

  @type t :: %__MODULE__{
          hash: String.t(),
          name: String.t() | nil,
          magnet: String.t(),
          state: state(),
          error: String.t() | nil,
          failure_type: failure_type(),
          rd_id: String.t() | nil,
          files: [map()] | nil,
          selected_files: [integer()] | nil,
          save_path: String.t() | nil,
          added_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          progress: float(),
          size: non_neg_integer(),
          downloaded: non_neg_integer(),
          expected_files: pos_integer() | nil,
          retry_count: non_neg_integer(),
          servarr_url: String.t() | nil,
          servarr_api_key: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :hash,
    :name,
    :magnet,
    :state,
    :error,
    :failure_type,
    :rd_id,
    :files,
    :selected_files,
    :save_path,
    :added_at,
    :completed_at,
    :failed_at,
    :expected_files,
    :servarr_url,
    :servarr_api_key,
    progress: 0.0,
    size: 0,
    downloaded: 0,
    retry_count: 0,
    metadata: %{}
  ]

  @doc """
  Creates a new torrent from a magnet link.
  """
  @spec new(String.t(), String.t()) :: t()
  def new(hash, magnet) do
    save_path = Path.join(Aria2Debrid.Config.save_path(), String.downcase(hash))

    %__MODULE__{
      hash: String.downcase(hash),
      magnet: magnet,
      state: :pending,
      save_path: save_path,
      added_at: DateTime.utc_now()
    }
  end

  @doc """
  Transitions the torrent to a new state.
  """
  @spec transition(t(), state()) :: t()
  def transition(torrent, new_state) do
    require Logger
    Logger.debug("State transition: #{torrent.hash} #{torrent.state} -> #{new_state}")
    torrent = %{torrent | state: new_state}

    case new_state do
      :success ->
        %{torrent | completed_at: DateTime.utc_now(), progress: 100.0}

      :failed ->
        %{torrent | failed_at: DateTime.utc_now()}

      _ ->
        torrent
    end
  end

  @doc """
  Sets an error on the torrent and transitions to failed state.
  """
  @spec set_error(t(), String.t()) :: t()
  def set_error(torrent, error) do
    torrent
    |> Map.put(:error, error)
    |> Map.put(:failure_type, :permanent)
    |> transition(:failed)
  end

  @doc """
  Sets a validation error on the torrent (triggers auto-redownload in Sonarr/Radarr).

  Validation errors include:
  - File count mismatch
  - FFprobe validation failures (no video/audio stream, sample file)
  - Media validation failures
  """
  @spec set_validation_error(t(), String.t()) :: t()
  def set_validation_error(torrent, error) do
    torrent
    |> Map.put(:error, error)
    |> Map.put(:failure_type, :validation)
    |> transition(:failed)
  end

  @doc """
  Sets a warning error on the torrent (does NOT trigger auto-redownload).

  Warning errors include:
  - Queue empty (API issue, timing issue)
  - Servarr API failures
  - Non-critical issues that shouldn't trigger retry/search
  """
  @spec set_warning_error(t(), String.t()) :: t()
  def set_warning_error(torrent, error) do
    torrent
    |> Map.put(:error, error)
    |> Map.put(:failure_type, :warning)
    |> transition(:failed)
  end

  @doc """
  Updates progress based on Real Debrid status.
  """
  @spec update_progress(t(), float()) :: t()
  def update_progress(torrent, progress) do
    %{torrent | progress: progress}
  end

  @doc """
  Updates the torrent with Real Debrid info.
  """
  @spec update_rd_info(t(), map()) :: t()
  def update_rd_info(torrent, rd_info) do
    %{
      torrent
      | rd_id: rd_info["id"],
        name: rd_info["filename"] || rd_info["original_filename"],
        files: rd_info["files"],
        size: rd_info["bytes"] || 0,
        progress: parse_progress(rd_info["progress"])
    }
  end

  @doc """
  Returns true if this torrent should be cleaned up.

  Only failed torrents are automatically cleaned up after the retention period.
  Completed/success torrents are NEVER automatically cleaned up - Sonarr/Radarr
  will handle removal via aria2.removeDownloadResult.
  """
  @spec should_cleanup?(t()) :: boolean()
  def should_cleanup?(%__MODULE__{state: :failed, failed_at: failed_at})
      when not is_nil(failed_at) do
    retention = Aria2Debrid.Config.failed_retention()
    elapsed = DateTime.diff(DateTime.utc_now(), failed_at, :millisecond)
    elapsed >= retention
  end

  def should_cleanup?(_), do: false

  @doc """
  Returns true if this torrent is in a processing state.
  """
  @spec processing?(t()) :: boolean()
  def processing?(%__MODULE__{state: state}) do
    state not in [:success, :failed]
  end

  @doc """
  Returns true if this torrent is complete.
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{state: :success}), do: true
  def complete?(_), do: false

  @doc """
  Returns true if this torrent has failed.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{state: :failed}), do: true
  def failed?(_), do: false

  # Private functions

  defp parse_progress(nil), do: 0.0
  defp parse_progress(progress) when is_float(progress), do: progress
  defp parse_progress(progress) when is_integer(progress), do: progress * 1.0

  defp parse_progress(progress) when is_binary(progress) do
    case Float.parse(progress) do
      {value, _} -> value
      :error -> 0.0
    end
  end
end

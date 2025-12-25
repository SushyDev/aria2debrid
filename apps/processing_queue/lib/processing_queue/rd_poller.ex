defmodule ProcessingQueue.RDPoller do
  @moduledoc """
  Unified Real-Debrid polling strategies.

  Provides consistent polling patterns for waiting on Real-Debrid operations:
  - Metadata polling (waiting for torrent info)
  - Download status polling (waiting for downloaded status)
  - File selection confirmation

  ## Usage

      # Poll until metadata is ready
      case RDPoller.poll_metadata(client, rd_id) do
        {:ok, info} -> # Torrent info ready
        {:error, :timeout} -> # Exceeded max retries
        {:error, reason} -> # RD error
      end

      # Poll until downloaded
      case RDPoller.poll_download(client, rd_id) do
        {:ok, info} -> # Download complete
        {:error, :not_downloaded, info} -> # Still downloading
        {:error, reason} -> # RD error
      end
  """

  require Logger

  @doc """
  Polls Real-Debrid for torrent info.

  Single poll with proper error handling.

  ## Returns
    - `{:ok, info}` - Torrent info retrieved successfully
    - `{:error, reason}` - API error occurred
  """
  @spec get_torrent_info(RealDebrid.Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_torrent_info(client, rd_id) do
    case RealDebrid.Api.TorrentInfo.get(client, rd_id) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        Logger.warning("Failed to get torrent info for #{rd_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Converts RealDebrid TorrentInfo to internal map format.
  """
  @spec info_to_map(struct()) :: map()
  def info_to_map(info) do
    %{
      "id" => info.id,
      "filename" => info.filename,
      "original_filename" => info.original_filename,
      "files" =>
        Enum.map(info.files || [], fn f ->
          %{"id" => f.id, "path" => f.path, "bytes" => f.bytes, "selected" => f.selected}
        end),
      "bytes" => info.bytes,
      "progress" => info.progress,
      "status" => info.status,
      "links" => info.links || []
    }
  end

  @doc """
  Checks RD torrent status and returns next action.

  ## Returns
    - `{:ready, info}` - Files ready for selection (waiting_files_selection)
    - `{:downloaded, info}` - Download complete
    - `{:downloading, info}` - Still downloading/queued
    - `{:error, reason, info}` - Terminal error state
  """
  @spec check_status(struct()) ::
          {:ready, struct()}
          | {:downloaded, struct()}
          | {:downloading, struct()}
          | {:error, atom(), struct()}
  def check_status(info) do
    case info.status do
      "waiting_files_selection" ->
        {:ready, info}

      "downloaded" ->
        {:downloaded, info}

      "magnet_error" ->
        {:error, :magnet_error, info}

      "error" ->
        {:error, :rd_error, info}

      "dead" ->
        {:error, :dead_torrent, info}

      status when status in ["queued", "downloading", "compressing", "uploading"] ->
        {:downloading, info}

      other_status ->
        Logger.debug("Unknown RD status: #{other_status}, treating as downloading")
        {:downloading, info}
    end
  end

  @doc """
  Polls for download completion.

  Used during the WAITING_DOWNLOAD state.

  ## Returns
    - `{:ok, info}` - Download complete (status = "downloaded")
    - `{:downloading, info}` - Still downloading (for retry decision)
    - `{:error, reason}` - Terminal error
  """
  @spec poll_download(RealDebrid.Client.t(), String.t()) ::
          {:ok, struct()} | {:downloading, struct()} | {:error, term()}
  def poll_download(client, rd_id) do
    case get_torrent_info(client, rd_id) do
      {:ok, info} ->
        case check_status(info) do
          {:downloaded, info} ->
            {:ok, info}

          {:downloading, info} ->
            {:downloading, info}

          {:ready, info} ->
            # Files selected but not downloaded yet
            {:downloading, info}

          {:error, reason, _info} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Selects files on Real-Debrid torrent.

  ## Parameters
    - `client` - RealDebrid client
    - `rd_id` - RealDebrid torrent ID
    - `file_ids` - List of file IDs to select

  ## Returns
    - `:ok` - Files selected successfully
    - `{:error, reason}` - Selection failed
  """
  @spec select_files(RealDebrid.Client.t(), String.t(), [integer()]) :: :ok | {:error, term()}
  def select_files(client, rd_id, file_ids) when is_list(file_ids) do
    file_ids_string = Enum.join(file_ids, ",")

    case RealDebrid.Api.SelectFiles.select(client, rd_id, file_ids_string) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to select files for #{rd_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Unrestricts a Real-Debrid link for streaming/validation.

  ## Returns
    - `{:ok, url, filename}` - Direct download URL and filename
    - `{:error, reason}` - Unrestrict failed
  """
  @spec unrestrict_link(RealDebrid.Client.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def unrestrict_link(client, link) do
    case RealDebrid.Api.UnrestrictLink.unrestrict(client, link) do
      {:ok, unrestricted} ->
        {:ok, unrestricted.download, unrestricted.filename}

      {:error, reason} ->
        Logger.warning("Failed to unrestrict link: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Deletes a torrent from Real-Debrid.

  ## Returns
    - `:ok` - Deleted successfully
    - `{:error, reason}` - Deletion failed
  """
  @spec delete_torrent(RealDebrid.Client.t(), String.t()) :: :ok | {:error, term()}
  def delete_torrent(client, rd_id) do
    case RealDebrid.Api.Delete.delete(client, rd_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete torrent #{rd_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Adds a magnet link to Real-Debrid.

  ## Returns
    - `{:ok, rd_id}` - Added successfully, returns RD torrent ID
    - `{:error, reason}` - Failed to add
  """
  @spec add_magnet(RealDebrid.Client.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def add_magnet(client, magnet) do
    case RealDebrid.Api.AddMagnet.add(client, magnet) do
      {:ok, response} ->
        {:ok, response.id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds a torrent file to Real-Debrid.

  ## Returns
    - `{:ok, rd_id}` - Added successfully, returns RD torrent ID
    - `{:error, reason}` - Failed to add
  """
  @spec add_torrent_file(RealDebrid.Client.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def add_torrent_file(client, torrent_data) do
    case RealDebrid.Api.AddTorrent.add(client, torrent_data) do
      {:ok, response} ->
        {:ok, response.id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets torrent links from Real-Debrid.

  The links array contains download URLs for selected files.

  ## Returns
    - `{:ok, links}` - List of download URLs
    - `{:error, reason}` - API error
  """
  @spec get_torrent_links(RealDebrid.Client.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def get_torrent_links(client, rd_id) do
    case get_torrent_info(client, rd_id) do
      {:ok, info} ->
        {:ok, info.links || []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Convenience function to get RealDebrid client from config.
  """
  @spec get_client() :: RealDebrid.Client.t() | nil
  def get_client do
    case Aria2Debrid.Config.real_debrid_token() do
      nil -> nil
      token -> RealDebrid.Client.new(token)
    end
  end
end

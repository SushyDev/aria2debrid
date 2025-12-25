defmodule ProcessingQueue.ServarrSync do
  @moduledoc """
  Servarr API interactions for synchronization and history.

  Handles all communication with Sonarr/Radarr for:
  - Fetching expected file counts from history
  - Triggering RefreshMonitoredDownloads
  - Getting grabbed download IDs for multi-tenant filtering
  - Notifying of failed downloads

  ## Multi-Tenant Support

  Each Servarr instance is identified by its URL and API key.
  Credentials are passed via the aria2 secret token in "url|api_key" format.

  ## Usage

      # Fetch expected file count
      {:ok, count} = ServarrSync.get_expected_file_count(url, api_key, infohash)

      # Get grabbed IDs for filtering
      {:ok, grabbed_set} = ServarrSync.get_grabbed_ids(url, api_key)

      # Trigger refresh
      :ok = ServarrSync.refresh(url, api_key)
  """

  require Logger

  @doc """
  Gets expected file count from Servarr history.

  Queries the Servarr history API to find grabbed events matching the infohash.
  For season packs, returns the count of episodes (multiple history entries).

  ## Parameters
    - `url` - Servarr base URL
    - `api_key` - Servarr API key
    - `infohash` - Torrent infohash (case-insensitive)

  ## Returns
    - `{:ok, count}` - Number of expected files
    - `{:error, :history_empty}` - No matching history entries
    - `{:error, reason}` - API error
  """
  @spec get_expected_file_count(String.t(), String.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def get_expected_file_count(url, api_key, infohash) do
    client = ServarrClient.new(url, api_key)

    case ServarrClient.get_history_items_by_download_id(client, infohash) do
      {:ok, []} ->
        Logger.warning("No history items found for #{infohash} in Servarr")
        {:error, :history_empty}

      {:ok, history_items} ->
        count = length(history_items)
        Logger.info("Found #{count} grabbed history item(s) for #{infohash}")
        {:ok, count}

      {:error, reason} ->
        Logger.error("Failed to fetch Servarr history: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets set of grabbed download IDs from Servarr.

  Used for multi-tenant filtering - each Servarr instance only sees
  downloads it has grabbed.

  ## Parameters
    - `url` - Servarr base URL
    - `api_key` - Servarr API key

  ## Returns
    - `{:ok, MapSet.t()}` - Set of infohashes (lowercase)
    - `{:error, reason}` - API error
  """
  @spec get_grabbed_ids(String.t(), String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def get_grabbed_ids(url, api_key) do
    client = ServarrClient.new(url, api_key)
    ServarrClient.get_grabbed_download_ids(client)
  end

  @doc """
  Triggers RefreshMonitoredDownloads on Servarr.

  Fire-and-forget refresh to update Servarr's view of downloads.

  ## Parameters
    - `url` - Servarr base URL
    - `api_key` - Servarr API key

  ## Returns
    - `:ok` - Refresh triggered (may still be processing)
    - `{:error, reason}` - Failed to trigger refresh
  """
  @spec refresh(String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def refresh(nil, _api_key), do: :ok
  def refresh(_url, nil), do: :ok

  def refresh(url, api_key) do
    client = ServarrClient.new(url, api_key)

    case ServarrClient.refresh_monitored_downloads(client) do
      :ok ->
        Logger.debug("Triggered RefreshMonitoredDownloads")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to trigger RefreshMonitoredDownloads: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Triggers RefreshMonitoredDownloads and waits for completion.

  ## Options
    - `:timeout` - Max wait time in ms (default: 30_000)
    - `:poll_interval` - Poll interval in ms (default: 500)

  ## Returns
    - `:ok` - Refresh completed
    - `{:error, :timeout}` - Timed out
    - `{:error, reason}` - API error
  """
  @spec refresh_and_wait(String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def refresh_and_wait(url, api_key, opts \\ [])
  def refresh_and_wait(nil, _api_key, _opts), do: {:error, :no_url}
  def refresh_and_wait(_url, nil, _opts), do: {:error, :no_api_key}

  def refresh_and_wait(url, api_key, opts) do
    client = ServarrClient.new(url, api_key)

    case ServarrClient.refresh_monitored_downloads_and_wait(client, opts) do
      :ok ->
        # Wait a bit for queue to be fully updated after command completes
        Process.sleep(2000)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Notifies Servarr that a download has failed.

  Marks matching queue items as failed, optionally blocklisting and triggering search.

  ## Parameters
    - `url` - Servarr base URL
    - `api_key` - Servarr API key  
    - `infohash` - Torrent infohash
    - `reason` - Failure reason for logging

  ## Options
    - `:blocklist` - Add to blocklist (default: from config)
    - `:search` - Trigger new search (default: from config)

  ## Returns
    - `{:ok, count}` - Number of queue items marked as failed
    - `{:error, reason}` - API error
  """
  @spec notify_failure(String.t() | nil, String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def notify_failure(url, api_key, infohash, reason, opts \\ [])
  def notify_failure(nil, _api_key, _infohash, _reason, _opts), do: {:ok, 0}
  def notify_failure(_url, nil, _infohash, _reason, _opts), do: {:ok, 0}

  def notify_failure(url, api_key, infohash, reason, opts) do
    unless Aria2Debrid.Config.notify_servarr_on_failure?() do
      Logger.debug("Servarr failure notification disabled, skipping for #{infohash}")
      {:ok, 0}
    else
      client = ServarrClient.new(url, api_key)

      opts = [
        blocklist: Keyword.get(opts, :blocklist, Aria2Debrid.Config.servarr_blocklist_on_failure?()),
        search: Keyword.get(opts, :search, Aria2Debrid.Config.servarr_search_on_failure?())
      ]

      case ServarrClient.mark_download_as_failed(client, infohash, opts) do
        {:ok, 0} ->
          Logger.debug("No queue items found in Servarr for #{infohash}")
          {:ok, 0}

        {:ok, count} ->
          Logger.info(
            "Marked #{count} queue item(s) as failed in Servarr for #{infohash}: #{reason} " <>
              "(blocklist: #{opts[:blocklist]}, search: #{opts[:search]})"
          )

          {:ok, count}

        {:error, err} ->
          Logger.warning("Failed to notify Servarr of failure for #{infohash}: #{inspect(err)}")
          {:error, err}
      end
    end
  end

  @doc """
  Filters torrents to only those belonging to a Servarr instance.

  Uses the Servarr's grabbed history to match infohashes.

  ## Parameters
    - `torrents` - List of torrent structs
    - `url` - Servarr base URL
    - `api_key` - Servarr API key

  ## Returns
    - Filtered list of torrents belonging to this Servarr
  """
  @spec filter_by_servarr([struct()], String.t() | nil, String.t() | nil) :: [struct()]
  def filter_by_servarr(_torrents, nil, _api_key) do
    Logger.error("No Servarr URL provided - returning empty list for multi-tenant security")
    []
  end

  def filter_by_servarr(_torrents, _url, nil) do
    Logger.error("No Servarr API key provided - returning empty list for multi-tenant security")
    []
  end

  def filter_by_servarr(torrents, url, api_key) do
    case get_grabbed_ids(url, api_key) do
      {:ok, grabbed_hashes} ->
        filtered =
          Enum.filter(torrents, fn torrent ->
            MapSet.member?(grabbed_hashes, String.downcase(torrent.hash))
          end)

        Logger.debug(
          "Filtered torrents by servarr history (#{url}): #{length(torrents)} -> #{length(filtered)}"
        )

        filtered

      {:error, reason} ->
        Logger.error(
          "Failed to fetch Servarr history for filtering (#{url}): #{inspect(reason)} - returning empty list"
        )

        []
    end
  end
end

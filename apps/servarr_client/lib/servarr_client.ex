defmodule ServarrClient do
  @moduledoc """
  HTTP client for Sonarr and Radarr APIs.

  Used to fetch queue information and history to determine expected file counts
  for torrent validation.
  """

  alias ServarrClient.{QueueItem, HistoryItem}

  @type client :: %{url: String.t(), api_key: String.t()}
  @type error :: {:error, term()}

  @doc """
  Creates a new client for a Servarr instance.

  ## Examples

      iex> ServarrClient.new("http://localhost:8989", "your-api-key")
      %{url: "http://localhost:8989", api_key: "your-api-key"}
  """
  @spec new(String.t(), String.t()) :: client()
  def new(url, api_key) do
    %{url: String.trim_trailing(url, "/"), api_key: api_key}
  end

  @doc """
  Tests connection to Servarr by calling /api/v3/system/status.
  """
  @spec test_connection(client()) :: :ok | error()
  def test_connection(client) do
    case request(client, "/api/v3/system/status", %{}) do
      {:ok, %{"version" => _version}} -> :ok
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches the download queue from Sonarr/Radarr.

  Returns a list of queue items that are currently being processed.
  """
  @spec get_queue(client()) :: {:ok, [QueueItem.t()]} | error()
  def get_queue(client) do
    case request(client, "/api/v3/queue", %{pageSize: 1000, includeUnknownSeriesItems: true}) do
      {:ok, %{"records" => records}} ->
        items = Enum.map(records, &QueueItem.from_api/1)
        {:ok, items}

      {:ok, response} when is_list(response) ->
        items = Enum.map(response, &QueueItem.from_api/1)
        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches an item from the queue by download ID (infohash).

  This is used to get the expected file count for a torrent.
  """
  @spec get_queue_item_by_download_id(client(), String.t()) ::
          {:ok, QueueItem.t() | nil} | error()
  def get_queue_item_by_download_id(client, download_id) do
    case get_queue(client) do
      {:ok, items} ->
        item =
          Enum.find(items, fn item ->
            String.downcase(item.download_id || "") == String.downcase(download_id)
          end)

        {:ok, item}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches recent history from Sonarr/Radarr.

  Used to check if a torrent was recently grabbed/imported.
  """
  @spec get_history(client(), keyword()) :: {:ok, [HistoryItem.t()]} | error()
  def get_history(client, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 50)

    case request(client, "/api/v3/history", %{pageSize: page_size}) do
      {:ok, %{"records" => records}} ->
        items = Enum.map(records, &HistoryItem.from_api/1)
        {:ok, items}

      {:ok, response} when is_list(response) ->
        items = Enum.map(response, &HistoryItem.from_api/1)
        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches grabbed download IDs for multi-tenant filtering.

  Returns a MapSet of infohashes from the Servarr's grabbed history.
  Uses `/api/v3/history/since?eventType=grabbed&date=<date>` which works for both Sonarr and Radarr.

  The `/api/v3/history/since` endpoint returns ALL matching records without pagination,
  ensuring we never miss torrents within the time window.

  ## Options
    - `:days` - Number of days of history to fetch (default: from application config or 7)
  """
  @spec get_grabbed_download_ids(client(), keyword()) :: {:ok, MapSet.t(String.t())} | error()
  def get_grabbed_download_ids(client, opts \\ []) do
    default_days = Application.get_env(:servarr_client, :history_lookback_days, 7)
    days = Keyword.get(opts, :days, default_days)
    since_date = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_iso8601()

    case request(client, "/api/v3/history/since", %{eventType: "grabbed", date: since_date}) do
      {:ok, records} when is_list(records) ->
        download_ids =
          records
          |> Enum.map(fn record ->
            Map.get(record, "downloadId") || Map.get(record, :download_id)
          end)
          |> Enum.filter(&(&1 != nil))
          |> Enum.map(&String.downcase/1)
          |> MapSet.new()

        {:ok, download_ids}

      {:ok, _unexpected_format} ->
        {:error, :unexpected_response_format}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Finds a history item by download ID (infohash).
  """
  @spec get_history_by_download_id(client(), String.t()) :: {:ok, HistoryItem.t() | nil} | error()
  def get_history_by_download_id(client, download_id) do
    case get_history(client, page_size: 100) do
      {:ok, items} ->
        item =
          Enum.find(items, fn item ->
            String.downcase(item.download_id || "") == String.downcase(download_id)
          end)

        {:ok, item}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches all history items matching a download ID (infohash).

  Returns a list of grabbed events because season packs can have multiple history records
  (one per episode). Only returns 'grabbed' events for counting expected files.

  **Important:** This deduplicates by episode_id (Sonarr) or movie_id (Radarr) to handle
  re-grabs of the same content. Each unique episode/movie counts once, regardless of
  how many times it was grabbed.
  """
  @spec get_history_items_by_download_id(client(), String.t()) ::
          {:ok, [HistoryItem.t()]} | error()
  def get_history_items_by_download_id(client, download_id) do
    case get_history(client, page_size: 200) do
      {:ok, items} ->
        matching =
          items
          |> Enum.filter(fn item ->
            String.downcase(item.download_id || "") == String.downcase(download_id) and
              HistoryItem.grabbed?(item)
          end)
          |> deduplicate_history_items()

        {:ok, matching}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Deduplicates history items by episode_id (Sonarr) or movie_id (Radarr).
  # This handles re-grabs of the same content - each episode/movie counts once.
  defp deduplicate_history_items(items) do
    items
    |> Enum.uniq_by(fn item ->
      # For Sonarr: use episode_id, for Radarr: use movie_id
      # If neither is present (shouldn't happen), use the history item id as fallback
      item.episode_id || item.movie_id || item.id
    end)
  end

  @doc """
  Marks a queue item as failed in Sonarr/Radarr.

  This triggers the arr to search for an alternative release.

  ## Options
    - `:blocklist` - Whether to add the release to the blocklist (default: true)
    - `:search` - Whether to trigger a new search for alternatives (default: true)
  """
  @spec mark_as_failed(client(), integer(), keyword()) :: :ok | error()
  def mark_as_failed(client, queue_id, opts \\ []) do
    blocklist = Keyword.get(opts, :blocklist, true)
    search = Keyword.get(opts, :search, true)

    skip_redownload = !search

    params = %{blocklist: blocklist, skipRedownload: skip_redownload}

    case request(client, "/api/v3/queue/#{queue_id}", params, :delete) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Marks all queue items for a download ID (infohash) as failed.

  This finds all queue items matching the download_id and marks each as failed,
  triggering Sonarr/Radarr to search for alternative releases.

  Returns {:ok, count} where count is the number of items marked as failed,
  or {:error, reason} if fetching the queue failed.

  ## Options
    - `:blocklist` - Whether to add the release to the blocklist (default: true)
    - `:search` - Whether to trigger a new search for alternatives (default: true)
  """
  @spec mark_download_as_failed(client(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | error()
  def mark_download_as_failed(client, download_id, opts \\ []) do
    case get_queue_items_by_download_id(client, download_id) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, items} ->
        results =
          Enum.map(items, fn item ->
            mark_as_failed(client, item.id, opts)
          end)

        success_count = Enum.count(results, &(&1 == :ok))
        {:ok, success_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Triggers a refresh of monitored downloads in Sonarr/Radarr.
  """
  @spec refresh_monitored_downloads(client()) :: :ok | error()
  def refresh_monitored_downloads(client) do
    case request(client, "/api/v3/command", %{}, :post, %{name: "RefreshMonitoredDownloads"}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Triggers a refresh of monitored downloads and waits for completion.

  ## Options
    - `:timeout` - Maximum time to wait in milliseconds (default: 30_000)
    - `:poll_interval` - Interval between status checks in milliseconds (default: 500)
  """
  @spec refresh_monitored_downloads_and_wait(client(), keyword()) :: :ok | error()
  def refresh_monitored_downloads_and_wait(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    poll_interval = Keyword.get(opts, :poll_interval, 500)

    case request(client, "/api/v3/command", %{}, :post, %{name: "RefreshMonitoredDownloads"}) do
      {:ok, %{"id" => command_id}} ->
        wait_for_command(client, command_id, timeout, poll_interval)

      {:ok, _} ->
        Process.sleep(2000)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches all queue items matching a download ID (infohash).

  Returns a list because season packs can have multiple queue records
  (one per episode).
  """
  @spec get_queue_items_by_download_id(client(), String.t()) ::
          {:ok, [QueueItem.t()]} | error()
  def get_queue_items_by_download_id(client, download_id) do
    case get_queue(client) do
      {:ok, items} ->
        matching =
          Enum.filter(items, fn item ->
            String.downcase(item.download_id || "") == String.downcase(download_id)
          end)

        {:ok, matching}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_command(client, command_id, timeout, poll_interval) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_command(client, command_id, deadline, poll_interval)
  end

  defp do_wait_for_command(client, command_id, deadline, poll_interval) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case request(client, "/api/v3/command/#{command_id}") do
        {:ok, %{"status" => "completed"}} ->
          :ok

        {:ok, %{"status" => "failed", "message" => message}} ->
          {:error, {:command_failed, message}}

        {:ok, %{"status" => status}} when status in ["queued", "started"] ->
          Process.sleep(poll_interval)
          do_wait_for_command(client, command_id, deadline, poll_interval)

        {:ok, _} ->
          Process.sleep(poll_interval)
          do_wait_for_command(client, command_id, deadline, poll_interval)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request(client, path, params \\ %{}, method \\ :get, body \\ nil) do
    url = client.url <> path

    req =
      Req.new(
        url: url,
        method: method,
        headers: [
          {"X-Api-Key", client.api_key},
          {"Accept", "application/json"}
        ]
      )
      |> Req.merge(params: params)

    req = if body, do: Req.merge(req, json: body), else: req

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end
end

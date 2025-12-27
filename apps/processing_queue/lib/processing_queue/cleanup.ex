defmodule ProcessingQueue.Cleanup do
  @moduledoc """
  Automatic cleanup of failed torrents after retention period with concurrent processing.

  This module periodically checks for failed torrents and removes them from the queue
  after they've been in the failed state for the configured retention period (default: 5 minutes).

  ## Why Automatic Cleanup is Needed

  Sonarr's aria2 client implementation has a limitation:
  - The `CanBeRemoved` flag is ONLY set to true for completed downloads (status="complete")
  - Failed downloads (status="error") have `CanBeRemoved=false`
  - Even with `RemoveFailedDownloads=true`, Sonarr will NOT remove failed aria2 downloads
  - The `RemoveFailedDownloads` setting is effectively ignored for aria2 due to this limitation

  Sonarr's Failed Download Handler:
  1. Detects the failed download via aria2 status
  2. Blocklists the release
  3. Triggers a new search for alternatives
  4. **Does NOT automatically remove the failed download from aria2** (due to CanBeRemoved limitation)

  Without automatic cleanup, failed downloads would accumulate indefinitely in the
  `aria2.tellStopped` results, cluttering the UI and consuming memory.

  ## Timing Strategy

  The 5-minute retention period ensures:
  - Sonarr has time to detect the failure and run the Failed Download Handler
  - The failed download remains visible in Sonarr's queue long enough for inspection
  - Failed downloads don't accumulate indefinitely
  - Real-Debrid resources are cleaned up based on failure type (see below)

  ## Real-Debrid Cleanup Strategy

  Real-Debrid resources are managed based on failure type using `ErrorClassifier`:

  - **Validation failures** (`:validation`) - KEEP RD resources
    - Sonarr may need to inspect the files
    - Allows manual investigation of what went wrong
    - Examples: file count mismatch, media validation failure

  - **Permanent failures** (`:permanent`) - DELETE RD resources
    - Non-retryable errors, no reason to keep resources
    - Saves RD quota and storage
    - Examples: RD API errors, network timeouts, invalid magnets

  - **Warning failures** (`:warning`) - KEEP RD resources
    - May recover or need manual intervention
    - Examples: empty queue, temporary Servarr API failures

  - **Application errors** (`:application`) - KEEP RD resources
    - System/config issues requiring admin intervention
    - Resources kept until admin fixes the problem
    - Examples: missing FFmpeg, invalid configuration

  ## Completed Downloads

  Completed downloads (status="success") are NOT automatically cleaned up by this module:
  - Sonarr WILL remove them via `aria2.removeDownloadResult` (if RemoveCompletedDownloads=true)
  - Real-Debrid resources ALWAYS remain available when completed downloads are removed
  - This allows Sonarr to control when completed downloads are cleaned up
  - RD resources stay available for the user even after Sonarr removes the download

  ## Manual Removal

  When a download is manually removed (via `aria2.remove` or `aria2.forceRemove`):
  - Failed downloads: RD cleanup follows the same failure type rules as automatic cleanup
  - Completed downloads: RD resources are kept (user may want them available)
  - Processing downloads: RD resources are kept (user may want to investigate)

  ## Concurrency

  Cleanup operations are performed concurrently using `Task.async_stream/3` with:
  - Max concurrency: 10 concurrent cleanup operations
  - Timeout: 15 seconds per cleanup operation
  - Failed tasks are killed on timeout

  This provides faster cleanup for large batches of failed torrents.

  ## Configuration

  - `FAILED_RETENTION_MS` - Milliseconds to retain failed torrents (default: 300000 = 5 minutes)
  - `CLEANUP_INTERVAL_MS` - Milliseconds between cleanup runs (default: 60000 = 1 minute)
  """

  use GenServer

  alias ProcessingQueue.{Manager, Torrent}

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval_sec = Aria2Debrid.Config.cleanup_interval() / 1000
    retention_sec = Aria2Debrid.Config.failed_retention() / 1000

    Logger.info(
      "Cleanup module started: checking every #{interval_sec}s, retaining failed torrents for #{retention_sec}s"
    )

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_failed_torrents()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    interval = Aria2Debrid.Config.cleanup_interval()
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_failed_torrents do
    torrents = Manager.list_torrents()
    failed_count = Enum.count(torrents, &(&1.state == :failed))

    Logger.debug("Cleanup check: #{length(torrents)} total torrents, #{failed_count} failed")

    # Identify torrents eligible for cleanup concurrently
    to_cleanup =
      torrents
      |> Task.async_stream(
        fn torrent ->
          if Torrent.should_cleanup?(torrent), do: torrent.hash, else: nil
        end,
        max_concurrency: System.schedulers_online() * 2,
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce([], fn
        {:ok, nil}, acc -> acc
        {:ok, hash}, acc -> [hash | acc]
        {:exit, _reason}, acc -> acc
      end)

    if length(to_cleanup) > 0 do
      Logger.info(
        "Cleaning up #{length(to_cleanup)} failed torrents (#{length(to_cleanup)} eligible for cleanup out of #{failed_count} failed)"
      )

      Enum.each(to_cleanup, fn hash ->
        Logger.debug("Cleanup: removing failed torrent #{hash}")
      end)

      Manager.cleanup_torrents(to_cleanup)
    else
      if failed_count > 0 do
        Logger.debug(
          "No failed torrents eligible for cleanup yet (#{failed_count} still within retention period)"
        )
      end
    end
  end
end

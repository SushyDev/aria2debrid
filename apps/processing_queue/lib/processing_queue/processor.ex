defmodule ProcessingQueue.Processor do
  @moduledoc """
  Processes a single torrent through the FSM state machine.

  ## State Flow

  ```
  pending → adding_rd → waiting_metadata → selecting_files → refreshing_info
  → fetching_queue → waiting_download → validating_count → validating_media
  → validating_path → success/failed
  ```

  ## State Responsibilities

  Each state has a single responsibility:
  - `:pending` - Initial state, transitions to adding_rd
  - `:adding_rd` - Adds magnet/torrent to Real-Debrid
  - `:waiting_metadata` - Polls RD until files are available
  - `:selecting_files` - Selects video/subtitle files on RD
  - `:refreshing_info` - Refreshes RD info after file selection
  - `:fetching_queue` - Fetches expected file count from Servarr history
  - `:waiting_download` - Waits for RD to complete download (if required)
  - `:validating_count` - Validates file count matches expected
  - `:validating_media` - Validates media via FFprobe
  - `:validating_path` - Validates files exist on filesystem
  - `:success` - Terminal success state
  - `:failed` - Terminal failure state
  """

  use GenServer, restart: :temporary

  alias ProcessingQueue.{
    ErrorClassifier,
    FailureHandler,
    FileSelector,
    Manager,
    RDPoller,
    ServarrSync,
    Torrent,
    ValidationPipeline
  }

  require Logger

  # Client API

  def start_link(%Torrent{} = torrent) do
    GenServer.start_link(__MODULE__, torrent, name: via_tuple(torrent.hash))
  end

  defp via_tuple(hash) do
    {:via, Registry, {ProcessingQueue.TorrentRegistry, hash}}
  end

  # Server callbacks

  @impl true
  def init(torrent) do
    send(self(), :process)
    {:ok, torrent}
  end

  @impl true
  def handle_info(:process, torrent) do
    case process_state(torrent) do
      {:ok, updated_torrent} ->
        handle_state_result(updated_torrent)

      {:error, reason, updated_torrent} ->
        handle_error_result(reason, updated_torrent)

      {:wait, delay, updated_torrent} ->
        handle_wait_result(delay, updated_torrent)
    end
  end

  # Result handlers

  defp handle_state_result(torrent) do
    Manager.update_torrent(torrent)

    if Torrent.processing?(torrent) do
      send(self(), :process)
      {:noreply, torrent}
    else
      handle_terminal_state(torrent)
    end
  end

  defp handle_error_result(reason, torrent) do
    Manager.update_torrent(torrent)
    Logger.error("[#{torrent.hash}] Failed: #{reason}")

    handle_terminal_state(torrent)
  end

  defp handle_wait_result(delay, torrent) do
    Manager.update_torrent(torrent)
    Process.send_after(self(), :process, delay)
    {:noreply, torrent}
  end

  defp handle_terminal_state(torrent) do
    Logger.info("[#{torrent.hash}] Reached terminal state: #{torrent.state}")

    # Trigger Servarr refresh so it sees the updated status
    trigger_servarr_refresh(torrent)

    # Handle RD cleanup based on failure type
    if torrent.state == :failed and torrent.rd_id do
      handle_failure_cleanup(torrent)
    end

    {:stop, :normal, torrent}
  end

  defp handle_failure_cleanup(torrent) do
    if ErrorClassifier.cleanup_rd?(torrent.failure_type) do
      Logger.debug("[#{torrent.hash}] Cleaning up RD torrent: #{torrent.rd_id}")
      cleanup_real_debrid(torrent)
    else
      Logger.info(
        "[#{torrent.hash}] Keeping RD torrent for #{torrent.failure_type} failure (RD ID: #{torrent.rd_id})"
      )
    end
  end

  # ============================================================================
  # State Machine Processing
  # ============================================================================

  # State: PENDING
  # Initial state - should not normally reach here as torrents start in adding_rd
  defp process_state(%Torrent{state: :pending} = torrent) do
    Logger.warning("[#{torrent.hash}] In unexpected :pending state, transitioning to adding_rd")
    {:ok, Torrent.transition(torrent, :adding_rd)}
  end

  # State: ADDING_RD
  # Adds the magnet/torrent to Real-Debrid (usually done in Manager, but handle if needed)
  defp process_state(%Torrent{state: :adding_rd} = torrent) do
    if torrent.rd_id do
      {:ok, Torrent.transition(torrent, :waiting_metadata)}
    else
      add_to_real_debrid(torrent)
    end
  end

  # State: WAITING_METADATA
  # Polls RD until torrent metadata (files) is available
  defp process_state(%Torrent{state: :waiting_metadata} = torrent) do
    Logger.debug("[#{torrent.hash}] Waiting for metadata")

    client = get_rd_client()

    case RDPoller.get_torrent_info(client, torrent.rd_id) do
      {:ok, info} ->
        handle_rd_status(torrent, info)

      {:error, reason} ->
        Logger.warning("[#{torrent.hash}] Failed to get torrent info: #{inspect(reason)}")
        {:wait, 5000, torrent}
    end
  end

  # State: SELECTING_FILES
  # Selects video and subtitle files on Real-Debrid
  defp process_state(%Torrent{state: :selecting_files} = torrent) do
    Logger.debug("[#{torrent.hash}] Selecting files")

    client = get_rd_client()

    if Enum.empty?(torrent.files || []) do
      # Files not populated yet, re-query
      refetch_and_select_files(torrent, client)
    else
      do_select_files(torrent, client)
    end
  end

  # State: REFRESHING_INFO
  # Refreshes torrent info after file selection to get updated selected status
  defp process_state(%Torrent{state: :refreshing_info} = torrent) do
    Logger.debug("[#{torrent.hash}] Refreshing torrent info after file selection")

    client = get_rd_client()

    case RDPoller.get_torrent_info(client, torrent.rd_id) do
      {:ok, info} ->
        updated_files = convert_files_to_map(info.files)
        updated = %{torrent | files: updated_files, progress: info.progress}
        {:ok, Torrent.transition(updated, :fetching_queue)}

      {:error, reason} ->
        Logger.warning("[#{torrent.hash}] Failed to refresh torrent info: #{inspect(reason)}")
        {:wait, 2000, torrent}
    end
  end

  # State: FETCHING_QUEUE
  # Fetches expected file count from Servarr history
  defp process_state(%Torrent{state: :fetching_queue} = torrent) do
    Logger.debug("[#{torrent.hash}] Fetching queue info from Servarr")

    if Aria2Debrid.Config.validate_file_count?() do
      fetch_expected_files_with_validation(torrent)
    else
      fetch_expected_files_without_validation(torrent)
    end
  end

  # State: WAITING_DOWNLOAD
  # Waits for Real-Debrid to complete the download
  defp process_state(%Torrent{state: :waiting_download} = torrent) do
    Logger.debug("[#{torrent.hash}] Waiting for download completion on Real-Debrid")

    if Aria2Debrid.Config.require_downloaded?() do
      check_download_status(torrent)
    else
      {:ok, Torrent.transition(torrent, :validating_count)}
    end
  end

  # State: VALIDATING_COUNT
  # Validates that the file count matches expected
  defp process_state(%Torrent{state: :validating_count} = torrent) do
    Logger.debug("[#{torrent.hash}] Validating file count")

    case ValidationPipeline.run_file_count(torrent) do
      :ok ->
        {:ok, Torrent.transition(torrent, :validating_media)}

      {:skip, reason} ->
        Logger.debug("[#{torrent.hash}] File count validation skipped: #{reason}")
        {:ok, Torrent.transition(torrent, :validating_media)}

      {:error, reason} ->
        handle_validation_failure(:file_count, reason, torrent)
    end
  end

  # State: VALIDATING_MEDIA
  # Validates media files via FFprobe
  defp process_state(%Torrent{state: :validating_media} = torrent) do
    Logger.debug("[#{torrent.hash}] Validating media")

    # Reset retry count for next phase
    updated = %{torrent | retry_count: 0}

    case ValidationPipeline.run_media(updated) do
      :ok ->
        {:ok, Torrent.transition(updated, :validating_path)}

      {:skip, reason} ->
        Logger.debug("[#{torrent.hash}] Media validation skipped: #{reason}")
        {:ok, Torrent.transition(updated, :validating_path)}

      {:error, reason} ->
        handle_validation_failure(:media, reason, updated)
    end
  end

  # State: VALIDATING_PATH
  # Validates that files exist on the filesystem (rclone mount)
  defp process_state(%Torrent{state: :validating_path} = torrent) do
    Logger.debug("[#{torrent.hash}] Validating path exists")

    if Aria2Debrid.Config.validate_paths?() do
      validate_path_with_retry(torrent)
    else
      {:ok, Torrent.transition(torrent, :success)}
    end
  end

  # Terminal states
  defp process_state(%Torrent{state: terminal} = torrent) when terminal in [:success, :failed] do
    {:ok, torrent}
  end

  # ============================================================================
  # State Handler Helpers
  # ============================================================================

  defp add_to_real_debrid(torrent) do
    Logger.debug("[#{torrent.hash}] Adding to Real-Debrid")
    client = get_rd_client()

    case RDPoller.add_magnet(client, torrent.magnet) do
      {:ok, rd_id} ->
        updated = %{torrent | rd_id: rd_id}
        {:ok, Torrent.transition(updated, :waiting_metadata)}

      {:error, reason} ->
        failure = FailureHandler.build_failure(:permanent, "Failed to add to RD: #{inspect(reason)}", %{})
        {:error, inspect(reason), apply_failure(torrent, failure)}
    end
  end

  defp handle_rd_status(torrent, info) do
    info_map = RDPoller.info_to_map(info)
    updated = Torrent.update_rd_info(torrent, info_map)

    case RDPoller.check_status(info) do
      {:ready, _} ->
        {:ok, Torrent.transition(updated, :selecting_files)}

      {:downloaded, _} ->
        {:ok, Torrent.transition(updated, :validating_count)}

      {:downloading, _} ->
        handle_downloading_status(updated, info.status)

      {:error, reason, _} ->
        handle_rd_error(updated, reason)
    end
  end

  defp handle_downloading_status(torrent, status) do
    if Aria2Debrid.Config.require_downloaded?() do
      reason = "Torrent not downloaded on RD (status: #{status})"
      notify_servarr_of_failure(torrent, reason)
      failure = FailureHandler.build_failure(:validation, reason, %{})
      {:error, reason, apply_failure(torrent, failure)}
    else
      Logger.info("[#{torrent.hash}] RD status is #{status}, proceeding (require_downloaded=false)")
      {:ok, Torrent.transition(torrent, :validating_count)}
    end
  end

  defp handle_rd_error(torrent, reason) do
    error_msg =
      case reason do
        :magnet_error -> "Invalid magnet link"
        :rd_error -> "Real-Debrid error"
        :dead_torrent -> "No seeders available"
        _ -> "RD error: #{inspect(reason)}"
      end

    failure = FailureHandler.build_failure(:permanent, error_msg, %{})
    {:error, error_msg, apply_failure(torrent, failure)}
  end

  defp refetch_and_select_files(torrent, client) do
    Logger.debug("[#{torrent.hash}] Files not available, re-querying torrent info")

    case RDPoller.get_torrent_info(client, torrent.rd_id) do
      {:ok, info} ->
        if Enum.empty?(info.files) do
          Logger.debug("[#{torrent.hash}] Files still not available, waiting")
          {:wait, 2000, torrent}
        else
          info_map = RDPoller.info_to_map(info)
          updated = Torrent.update_rd_info(torrent, info_map)
          do_select_files(updated, client)
        end

      {:error, reason} ->
        Logger.warning("[#{torrent.hash}] Failed to re-query torrent info: #{inspect(reason)}")
        {:wait, 2000, torrent}
    end
  end

  defp do_select_files(torrent, client) do
    files = torrent.files || []
    selected_ids = FileSelector.select(files)

    Logger.debug("[#{torrent.hash}] Selected #{length(selected_ids)} files: #{inspect(selected_ids)}")

    if Enum.empty?(selected_ids) do
      # This is a validation failure - the torrent doesn't have valid video files
      # Sonarr should trigger a re-search for a better release
      notify_servarr_of_failure(torrent, "No valid video files in torrent")
      failure = FailureHandler.build_failure(:validation, "No valid files to select", %{})
      {:error, "No valid files to select", apply_failure(torrent, failure)}
    else
      case RDPoller.select_files(client, torrent.rd_id, selected_ids) do
        :ok ->
          updated = %{torrent | selected_files: selected_ids}
          {:ok, Torrent.transition(updated, :refreshing_info)}

        {:error, reason} ->
          failure = FailureHandler.build_failure(:permanent, "File selection failed: #{inspect(reason)}", %{})
          {:error, "File selection failed", apply_failure(torrent, failure)}
      end
    end
  end

  defp fetch_expected_files_with_validation(torrent) do
    cond do
      missing_servarr_url?(torrent) ->
        failure = FailureHandler.build_failure(:warning, "Missing Servarr URL", %{})
        {:error, "File count validation enabled but no Servarr URL", apply_failure(torrent, failure)}

      missing_servarr_api_key?(torrent) ->
        failure = FailureHandler.build_failure(:warning, "Missing Servarr API key", %{})
        {:error, "File count validation enabled but no Servarr API key", apply_failure(torrent, failure)}

      true ->
        handle_queue_fetch(torrent)
    end
  end

  defp fetch_expected_files_without_validation(torrent) do
    updated =
      if torrent.servarr_url && torrent.servarr_api_key do
        trigger_servarr_refresh(torrent)
        Process.sleep(2000)

        case ServarrSync.get_expected_file_count(torrent.servarr_url, torrent.servarr_api_key, torrent.hash) do
          {:ok, count} -> %{torrent | expected_files: count}
          {:error, _} -> torrent
        end
      else
        torrent
      end

    {:ok, Torrent.transition(updated, :waiting_download)}
  end

  defp handle_queue_fetch(torrent) do
    max_retries = 5

    case ServarrSync.get_expected_file_count(torrent.servarr_url, torrent.servarr_api_key, torrent.hash) do
      {:ok, count} ->
        updated = %{torrent | expected_files: count, retry_count: 0}
        {:ok, Torrent.transition(updated, :waiting_download)}

      {:error, :history_empty} ->
        if torrent.retry_count < max_retries do
          Logger.warning(
            "[#{torrent.hash}] History empty, retrying (#{torrent.retry_count + 1}/#{max_retries})"
          )
          {:wait, 3000, %{torrent | retry_count: torrent.retry_count + 1}}
        else
          failure = FailureHandler.build_failure(:warning, "History empty after #{max_retries} retries", %{})
          {:error, "Servarr history empty after retries", apply_failure(torrent, failure)}
        end

      {:error, reason} ->
        failure = FailureHandler.build_failure(:warning, "Servarr API error: #{inspect(reason)}", %{})
        {:error, "Failed to fetch Servarr history", apply_failure(torrent, failure)}
    end
  end

  defp check_download_status(torrent) do
    client = get_rd_client()

    case RDPoller.poll_download(client, torrent.rd_id) do
      {:ok, _info} ->
        Logger.info("[#{torrent.hash}] Download complete on Real-Debrid")
        {:ok, Torrent.transition(torrent, :validating_count)}

      {:downloading, info} ->
        reason = "Torrent not downloaded on RD (status: #{info.status})"
        notify_servarr_of_failure(torrent, reason)
        failure = FailureHandler.build_failure(:validation, reason, %{})
        {:error, reason, apply_failure(torrent, failure)}

      {:error, reason} ->
        Logger.warning("[#{torrent.hash}] Failed to check download status: #{inspect(reason)}")
        {:wait, 5000, torrent}
    end
  end

  defp handle_validation_failure(phase, reason, torrent) do
    error_msg = "#{phase} validation failed: #{inspect(reason)}"
    notify_servarr_of_failure(torrent, error_msg)
    failure = FailureHandler.build_failure(:validation, error_msg, %{phase: phase})
    {:error, error_msg, apply_failure(torrent, failure)}
  end

  defp validate_path_with_retry(torrent) do
    save_path = torrent.save_path
    max_retries = Aria2Debrid.Config.path_validation_retries()

    if save_path && File.exists?(save_path) && path_has_files?(save_path) do
      Logger.info("[#{torrent.hash}] Path validated: #{save_path}")
      {:ok, Torrent.transition(torrent, :success)}
    else
      if torrent.retry_count >= max_retries do
        reason = "Path not found after #{max_retries} retries: #{save_path}"
        failure = FailureHandler.build_failure(:validation, reason, %{})
        {:error, reason, apply_failure(torrent, failure)}
      else
        Logger.debug(
          "[#{torrent.hash}] Path not ready (attempt #{torrent.retry_count + 1}/#{max_retries}): #{save_path}"
        )
        {:wait, Aria2Debrid.Config.path_validation_delay(), %{torrent | retry_count: torrent.retry_count + 1}}
      end
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp apply_failure(torrent, failure) do
    torrent
    |> Map.put(:error, to_string(failure.reason))
    |> Map.put(:failure_type, failure.type)
    |> Torrent.transition(:failed)
  end

  defp convert_files_to_map(files) when is_list(files) do
    Enum.map(files, fn f ->
      %{"id" => f.id, "path" => f.path, "bytes" => f.bytes, "selected" => f.selected}
    end)
  end

  defp convert_files_to_map(_), do: []

  defp path_has_files?(path) when is_binary(path) do
    case File.ls(path) do
      {:ok, files} -> Enum.any?(files)
      {:error, _} -> false
    end
  end

  defp path_has_files?(_), do: false

  defp missing_servarr_url?(%Torrent{servarr_url: nil}), do: true
  defp missing_servarr_url?(%Torrent{servarr_url: ""}), do: true
  defp missing_servarr_url?(_), do: false

  defp missing_servarr_api_key?(%Torrent{servarr_api_key: nil}), do: true
  defp missing_servarr_api_key?(%Torrent{servarr_api_key: ""}), do: true
  defp missing_servarr_api_key?(_), do: false

  defp get_rd_client do
    token = Aria2Debrid.Config.real_debrid_token()
    max_requests = Aria2Debrid.Config.requests_per_minute()
    max_retries = Aria2Debrid.Config.max_retries()

    RealDebrid.Client.new(token,
      max_requests_per_minute: max_requests,
      max_retries: max_retries
    )
  end

  # ============================================================================
  # Servarr Integration
  # ============================================================================

  defp trigger_servarr_refresh(%Torrent{servarr_url: nil}), do: :ok
  defp trigger_servarr_refresh(%Torrent{servarr_api_key: nil}), do: :ok

  defp trigger_servarr_refresh(torrent) do
    case ServarrSync.refresh(torrent.servarr_url, torrent.servarr_api_key) do
      :ok ->
        Logger.debug("[#{torrent.hash}] Triggered Servarr refresh")

      {:error, reason} ->
        Logger.warning("[#{torrent.hash}] Failed to trigger Servarr refresh: #{inspect(reason)}")
    end

    :ok
  end

  defp notify_servarr_of_failure(%Torrent{servarr_url: nil}, _reason), do: :ok
  defp notify_servarr_of_failure(%Torrent{servarr_api_key: nil}, _reason), do: :ok

  defp notify_servarr_of_failure(torrent, reason) do
    ServarrSync.notify_failure(
      torrent.servarr_url,
      torrent.servarr_api_key,
      torrent.hash,
      reason
    )
  end

  # ============================================================================
  # Real-Debrid Cleanup
  # ============================================================================

  defp cleanup_real_debrid(%Torrent{rd_id: nil}), do: :ok

  defp cleanup_real_debrid(torrent) do
    case RDPoller.get_client() do
      nil ->
        Logger.warning("[#{torrent.hash}] No RD client available for cleanup")
        :ok

      client ->
        case RDPoller.delete_torrent(client, torrent.rd_id) do
          :ok ->
            Logger.info("[#{torrent.hash}] Deleted from Real-Debrid (RD ID: #{torrent.rd_id})")
            :ok

          {:error, reason} ->
            Logger.warning("[#{torrent.hash}] Failed to delete from RD: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end
end

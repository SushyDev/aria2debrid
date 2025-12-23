defmodule ProcessingQueue.Processor do
  @moduledoc """
  Processes a single torrent through the state machine.

  State machine flow:
  PENDING → ADDING_RD → WAITING_METADATA → SELECTING_FILES → REFRESHING_INFO →
  FETCHING_QUEUE → VALIDATING_COUNT → VALIDATING_MEDIA → WAITING_DOWNLOAD → 
  VALIDATING_PATH → SUCCESS/FAILED
  """

  use GenServer, restart: :temporary

  alias ProcessingQueue.{Torrent, Manager}

  require Logger

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
        Manager.update_torrent(updated_torrent)

        if Torrent.processing?(updated_torrent) do
          send(self(), :process)
          {:noreply, updated_torrent}
        else
          Logger.info("Torrent #{torrent.hash} reached terminal state: #{updated_torrent.state}")

          trigger_servarr_refresh(updated_torrent)

          if updated_torrent.state == :failed and updated_torrent.rd_id do
            if updated_torrent.failure_type == :validation do
              Logger.info(
                "Torrent #{updated_torrent.hash} failed validation, keeping in RD for Servarr to see error (RD ID: #{updated_torrent.rd_id})"
              )
            else
              Logger.debug(
                "Torrent #{updated_torrent.hash} in :failed terminal state with RD ID #{updated_torrent.rd_id}, triggering cleanup"
              )

              cleanup_real_debrid_on_failure(updated_torrent)
            end
          else
            if updated_torrent.state == :failed do
              Logger.debug(
                "Torrent #{updated_torrent.hash} in :failed state but no RD ID to cleanup"
              )
            end
          end

          {:stop, :normal, updated_torrent}
        end

      {:error, reason, updated_torrent} ->
        Manager.update_torrent(updated_torrent)
        Logger.error("Torrent #{torrent.hash} failed: #{reason}")

        trigger_servarr_refresh(updated_torrent)

        if updated_torrent.failure_type == :validation do
          Logger.info(
            "Torrent #{updated_torrent.hash} failed validation, keeping in RD for Servarr to see error (RD ID: #{updated_torrent.rd_id})"
          )
        else
          # For non-validation failures (e.g., warnings, RD errors), cleanup immediately
          if updated_torrent.rd_id do
            Logger.debug(
              "Torrent #{updated_torrent.hash} failed with RD ID #{updated_torrent.rd_id}, triggering cleanup"
            )

            cleanup_real_debrid_on_failure(updated_torrent)
          else
            Logger.debug("Torrent #{updated_torrent.hash} failed but no RD ID to cleanup")
          end
        end

        {:stop, :normal, updated_torrent}

      {:wait, delay, updated_torrent} ->
        Manager.update_torrent(updated_torrent)
        Process.send_after(self(), :process, delay)
        {:noreply, updated_torrent}
    end
  end

  # State machine processing

  defp process_state(%Torrent{state: :pending} = torrent) do
    # Should not reach here - torrents are added directly to waiting_metadata
    # after RD add completes in Manager
    Logger.warning(
      "Torrent #{torrent.hash} in unexpected :pending state, transitioning to adding_rd"
    )

    {:ok, Torrent.transition(torrent, :adding_rd)}
  end

  defp process_state(%Torrent{state: :adding_rd} = torrent) do
    # Should not reach here - RD add is now done synchronously in Manager
    Logger.warning("Torrent #{torrent.hash} in unexpected :adding_rd state")

    if torrent.rd_id do
      # Already has RD ID, just transition
      {:ok, Torrent.transition(torrent, :waiting_metadata)}
    else
      # Need to add to RD
      Logger.debug("Adding torrent #{torrent.hash} to Real Debrid")
      client = get_rd_client()

      case RealDebrid.Api.AddMagnet.add(client, torrent.magnet) do
        {:ok, response} ->
          rd_id = response.id
          updated = %{torrent | rd_id: rd_id}
          {:ok, Torrent.transition(updated, :waiting_metadata)}

        {:error, reason} ->
          {:error, "Failed to add to Real Debrid: #{inspect(reason)}",
           Torrent.set_error(torrent, "RD add failed")}
      end
    end
  end

  defp process_state(%Torrent{state: :waiting_metadata} = torrent) do
    Logger.debug("Waiting for metadata for torrent #{torrent.hash}")

    client = get_rd_client()

    case RealDebrid.Api.TorrentInfo.get(client, torrent.rd_id) do
      {:ok, info} ->
        # Convert to map format expected by update_rd_info
        info_map = %{
          "id" => info.id,
          "filename" => info.filename,
          "original_filename" => info.original_filename,
          "files" =>
            Enum.map(info.files, fn f ->
              %{"id" => f.id, "path" => f.path, "bytes" => f.bytes, "selected" => f.selected}
            end),
          "bytes" => info.bytes,
          "progress" => info.progress
        }

        updated = Torrent.update_rd_info(torrent, info_map)

        case info.status do
          "waiting_files_selection" ->
            {:ok, Torrent.transition(updated, :selecting_files)}

          "magnet_error" ->
            {:error, "Magnet error", Torrent.set_error(updated, "Invalid magnet link")}

          "error" ->
            {:error, "RD error", Torrent.set_error(updated, "Real Debrid error")}

          "dead" ->
            {:error, "Dead torrent", Torrent.set_error(updated, "No seeders available")}

          "downloaded" ->
            {:ok, Torrent.transition(updated, :validating_count)}

          other_status ->
            # Not downloaded yet - behavior depends on require_downloaded? config
            if Aria2Debrid.Config.require_downloaded?() do
              # Use validation error so Sonarr/Radarr will auto-redownload
              reason = "Torrent not downloaded on RD (status: #{other_status})"
              notify_servarr_of_failure(updated, reason)

              {:error, reason,
               Torrent.set_validation_error(updated, "RD status: #{other_status}")}
            else
              Logger.info(
                "Torrent #{torrent.hash} RD status is #{other_status}, proceeding (require_downloaded=false)"
              )

              {:ok, Torrent.transition(updated, :validating_count)}
            end
        end

      {:error, reason} ->
        Logger.warning("Failed to get torrent info: #{inspect(reason)}")
        {:wait, 5000, torrent}
    end
  end

  defp process_state(%Torrent{state: :selecting_files} = torrent) do
    Logger.debug("Selecting files for torrent #{torrent.hash}")

    client = get_rd_client()
    files = torrent.files || []

    # If files haven't been populated yet, wait for metadata to be available
    if Enum.empty?(files) do
      Logger.debug("Files not yet available for #{torrent.hash}, waiting for metadata")
      {:wait, 2000, torrent}
    else
      # Select video files and configured additional files
      selected_ids = select_files(files)

      if Enum.empty?(selected_ids) do
        {:error, "No valid files to select", Torrent.set_error(torrent, "No video files found")}
      else
        # Convert to comma-separated string for API
        file_ids_string = Enum.join(selected_ids, ",")

        case RealDebrid.Api.SelectFiles.select(client, torrent.rd_id, file_ids_string) do
          :ok ->
            # After selecting files, we need to re-fetch torrent info to get updated file status
            # The torrent.files still has old selected values, refresh them
            updated = %{torrent | selected_files: selected_ids}
            {:ok, Torrent.transition(updated, :refreshing_info)}

          {:error, reason} ->
            {:error, "Failed to select files: #{inspect(reason)}",
             Torrent.set_error(torrent, "File selection failed")}
        end
      end
    end
  end

  defp process_state(%Torrent{state: :refreshing_info} = torrent) do
    Logger.debug("Refreshing torrent info after file selection for #{torrent.hash}")

    client = get_rd_client()

    case RealDebrid.Api.TorrentInfo.get(client, torrent.rd_id) do
      {:ok, info} ->
        # Update files with new selected status
        updated_files =
          Enum.map(info.files, fn f ->
            %{"id" => f.id, "path" => f.path, "bytes" => f.bytes, "selected" => f.selected}
          end)

        updated = %{torrent | files: updated_files, progress: info.progress}
        {:ok, Torrent.transition(updated, :fetching_queue)}

      {:error, reason} ->
        Logger.warning("Failed to refresh torrent info: #{inspect(reason)}")
        {:wait, 2000, torrent}
    end
  end

  defp process_state(%Torrent{state: :fetching_queue} = torrent) do
    Logger.debug("Fetching queue info for torrent #{torrent.hash}")

    if Aria2Debrid.Config.validate_file_count?() do
      # File count validation is enabled - we need Servarr credentials
      cond do
        is_nil(torrent.servarr_url) or torrent.servarr_url == "" ->
          {:error, "File count validation enabled but no Servarr URL provided",
           Torrent.set_warning_error(
             torrent,
             "Missing Servarr URL - configure download client directory"
           )}

        is_nil(torrent.servarr_api_key) or torrent.servarr_api_key == "" ->
          {:error, "File count validation enabled but no Servarr API key provided",
           Torrent.set_warning_error(
             torrent,
             "Missing Servarr API key - configure download client directory"
           )}

        true ->
          # Trigger Servarr to refresh its monitored downloads and wait for it to complete
          # This ensures Sonarr's queue is updated with this download before we query it
          Logger.debug("Triggering RefreshMonitoredDownloads and waiting for #{torrent.hash}")

          case trigger_servarr_refresh_and_wait(torrent) do
            :ok ->
              # Now fetch expected file count from Servarr queue
              case fetch_expected_files_from_servarr(torrent) do
                {:ok, updated} ->
                  {:ok, Torrent.transition(updated, :validating_count)}

                {:error, reason} ->
                  {:error, "Failed to fetch queue from Servarr: #{inspect(reason)}",
                   Torrent.set_warning_error(torrent, inspect(reason))}
              end

            {:error, reason} ->
              Logger.warning(
                "Failed to trigger Servarr refresh for #{torrent.hash}: #{inspect(reason)} - fetching queue anyway"
              )

              # Try fetching queue anyway
              case fetch_expected_files_from_servarr(torrent) do
                {:ok, updated} ->
                  {:ok, Torrent.transition(updated, :validating_count)}

                {:error, reason} ->
                  {:error, "Failed to fetch queue from Servarr: #{inspect(reason)}",
                   Torrent.set_warning_error(torrent, inspect(reason))}
              end
          end
      end
    else
      # File count validation disabled - credentials are optional
      updated =
        if torrent.servarr_url && torrent.servarr_api_key do
          trigger_servarr_refresh(torrent)
          Process.sleep(2000)

          case fetch_expected_files_from_servarr(torrent) do
            {:ok, updated} -> updated
            {:error, _reason} -> torrent
          end
        else
          Logger.debug("No Servarr credentials available, skipping queue fetch")
          torrent
        end

      {:ok, Torrent.transition(updated, :validating_count)}
    end
  end

  defp process_state(%Torrent{state: :validating_count} = torrent) do
    Logger.debug("Validating file count for torrent #{torrent.hash}")

    if Aria2Debrid.Config.validate_file_count?() do
      expected = torrent.expected_files || 1

      video_files =
        (torrent.files || [])
        |> Enum.filter(fn f -> f["selected"] == 1 end)
        |> Enum.filter(&video_file?/1)
        |> length()

      if video_files >= expected do
        {:ok, Torrent.transition(torrent, :validating_media)}
      else
        # File count mismatch triggers auto-redownload
        reason = "File count mismatch: expected #{expected}, got #{video_files}"
        notify_servarr_of_failure(torrent, reason)

        {:error, reason, Torrent.set_validation_error(torrent, reason)}
      end
    else
      {:ok, Torrent.transition(torrent, :validating_media)}
    end
  end

  defp process_state(%Torrent{state: :validating_media} = torrent) do
    Logger.debug("Validating media for torrent #{torrent.hash}")

    # Build the save path based on hash (uppercase)
    save_path = Path.join(Aria2Debrid.Config.save_path(), torrent.hash)
    # Reset retry_count for next phases
    updated = %{torrent | save_path: save_path, retry_count: 0}

    if Aria2Debrid.Config.media_validation_enabled?() do
      case validate_media_via_rd(updated) do
        :ok ->
          {:ok, Torrent.transition(updated, :waiting_download)}

        {:error, reason} ->
          # Media validation failures should trigger auto-redownload
          notify_servarr_of_failure(updated, reason)
          {:error, reason, Torrent.set_validation_error(updated, reason)}
      end
    else
      {:ok, Torrent.transition(updated, :waiting_download)}
    end
  end

  defp process_state(%Torrent{state: :waiting_download} = torrent) do
    Logger.debug("Waiting for download completion on Real-Debrid for #{torrent.hash}")

    if Aria2Debrid.Config.require_downloaded?() do
      client = get_rd_client()

      case RealDebrid.Api.TorrentInfo.get(client, torrent.rd_id) do
        {:ok, info} ->
          case info.status do
            "downloaded" ->
              Logger.info("Torrent #{torrent.hash} downloaded on Real-Debrid")
              {:ok, Torrent.transition(torrent, :validating_path)}

            other_status ->
              # require_downloaded? is true, so any non-downloaded status is a failure
              # Use validation error so Sonarr/Radarr will auto-redownload
              reason = "Torrent not downloaded on RD (status: #{other_status})"
              notify_servarr_of_failure(torrent, reason)

              {:error, reason,
               Torrent.set_validation_error(torrent, "RD status: #{other_status}")}
          end

        {:error, reason} ->
          Logger.warning("Failed to get torrent info: #{inspect(reason)}")
          {:wait, 5000, torrent}
      end
    else
      # Skip download verification, go straight to path validation
      {:ok, Torrent.transition(torrent, :validating_path)}
    end
  end

  defp process_state(%Torrent{state: :validating_path} = torrent) do
    Logger.debug("Validating path exists for torrent #{torrent.hash}")

    if Aria2Debrid.Config.validate_paths?() do
      save_path = torrent.save_path
      max_retries = Aria2Debrid.Config.path_validation_retries()

      if save_path && File.exists?(save_path) do
        Logger.info("Path validated for torrent #{torrent.hash}: #{save_path}")
        {:ok, Torrent.transition(torrent, :success)}
      else
        # Path doesn't exist yet - likely still syncing via rclone
        if torrent.retry_count >= max_retries do
          reason = "Path not found after #{max_retries} retries: #{save_path}"

          {:error, reason,
           Torrent.set_validation_error(torrent, "Path validation timeout - file not available")}
        else
          Logger.debug(
            "Path not found yet for #{torrent.hash} (attempt #{torrent.retry_count + 1}/#{max_retries}): #{save_path}"
          )

          updated = %{torrent | retry_count: torrent.retry_count + 1}
          {:wait, Aria2Debrid.Config.path_validation_delay(), updated}
        end
      end
    else
      # Path validation disabled, go straight to success
      {:ok, Torrent.transition(torrent, :success)}
    end
  end

  defp process_state(%Torrent{state: terminal} = torrent) when terminal in [:success, :failed] do
    # Already in terminal state
    {:ok, torrent}
  end

  # Helper functions

  defp get_rd_client do
    token = Aria2Debrid.Config.real_debrid_token()
    max_requests = Aria2Debrid.Config.requests_per_minute()
    max_retries = Aria2Debrid.Config.max_retries()

    RealDebrid.Client.new(token,
      max_requests_per_minute: max_requests,
      max_retries: max_retries
    )
  end

  defp select_files(files) do
    video_extensions = Aria2Debrid.Config.streamable_extensions()
    additional_extensions = Aria2Debrid.Config.additional_selectable_files()
    min_file_size = Aria2Debrid.Config.min_file_size_bytes()

    if Aria2Debrid.Config.select_all?() do
      Enum.map(files, & &1["id"])
    else
      files
      |> Enum.filter(fn file ->
        ext =
          file["path"]
          |> Path.extname()
          |> String.trim_leading(".")
          |> String.downcase()

        file_size = file["bytes"] || 0

        # Select video files that meet minimum size requirement
        # Or select additional files without size requirement
        (ext in video_extensions && file_size >= min_file_size) ||
          ext in additional_extensions
      end)
      |> Enum.map(& &1["id"])
    end
  end

  defp video_file?(file) do
    ext =
      file["path"]
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    ext in Aria2Debrid.Config.streamable_extensions()
  end

  # Validates media files via Real-Debrid streaming links
  # Returns :ok or {:error, reason}
  defp validate_media_via_rd(torrent) do
    client = get_rd_client()

    # Get torrent info to get the RD links
    case RealDebrid.Api.TorrentInfo.get(client, torrent.rd_id) do
      {:ok, info} ->
        links = info.links || []
        files = info.files || []

        # Match links to files to filter only video files
        # RD returns links in the same order as selected files
        selected_files =
          files
          |> Enum.filter(fn f -> f.selected == 1 end)
          |> Enum.filter(&video_file_struct?/1)

        # Take only as many links as we have selected video files
        video_links = Enum.take(links, length(selected_files))

        if Enum.empty?(video_links) do
          Logger.debug("No video links to validate for #{torrent.hash}")
          :ok
        else
          validate_rd_links(client, video_links, torrent.hash)
        end

      {:error, reason} ->
        Logger.warning("Failed to get torrent info for validation: #{inspect(reason)}")
        # Don't fail validation if we can't get info, let it continue
        :ok
    end
  end

  # Validates RD links by unrestricting them and running ffprobe
  defp validate_rd_links(client, links, hash) do
    Logger.debug("Validating #{length(links)} video links for #{hash}")

    Enum.reduce_while(links, :ok, fn link, _acc ->
      case validate_single_rd_link(client, link, hash) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_single_rd_link(client, link, hash) do
    # Unrestrict the link to get a direct download URL
    case RealDebrid.Api.UnrestrictLink.unrestrict(client, link) do
      {:ok, unrestricted} ->
        download_url = unrestricted.download
        filename = unrestricted.filename

        Logger.debug("Validating #{filename} via URL for #{hash}")

        case MediaValidator.validate_url(download_url) do
          :ok ->
            Logger.debug("Validation passed for #{filename}")
            :ok

          {:error, reason} ->
            Logger.warning("Media validation failed for #{filename}: #{reason}")
            {:error, "#{filename}: #{reason}"}
        end

      {:error, reason} ->
        Logger.warning("Failed to unrestrict link for validation: #{inspect(reason)}")
        # Don't fail if we can't unrestrict, continue processing
        :ok
    end
  end

  # Version of video_file? that works with struct format (from TorrentInfo)
  defp video_file_struct?(file) do
    ext =
      file.path
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    ext in Aria2Debrid.Config.streamable_extensions()
  end

  # Fetches expected file count from Servarr using credentials stored in torrent
  # For season packs, multiple queue items share the same download_id (one per episode)
  defp fetch_expected_files_from_servarr(torrent) do
    client = ServarrClient.new(torrent.servarr_url, torrent.servarr_api_key)

    case ServarrClient.get_queue_items_by_download_id(client, torrent.hash) do
      {:ok, []} ->
        # No queue items found
        if Aria2Debrid.Config.validate_file_count?() do
          # Validation is required - this is an error
          Logger.warning(
            "File count validation enabled but no queue items found for #{torrent.hash}"
          )

          {:error, "No queue items found in Servarr - torrent not in queue or already imported"}
        else
          # Validation is optional - just skip it
          Logger.info(
            "No queue items found for #{torrent.hash} in Servarr - skipping file count validation"
          )

          {:ok, torrent}
        end

      {:ok, queue_items} ->
        # Count queue items to get expected file count (one per expected file)
        expected_count = length(queue_items)

        Logger.info("Found #{expected_count} queue items for #{torrent.hash} in Servarr")

        {:ok, %{torrent | expected_files: expected_count}}

      {:error, reason} ->
        # Network/API errors
        if Aria2Debrid.Config.validate_file_count?() do
          # Validation is required - API errors are fatal
          Logger.warning("Failed to query Servarr queue for #{torrent.hash}: #{inspect(reason)}")

          {:error, "Failed to query Servarr queue: #{inspect(reason)}"}
        else
          # Validation is optional - continue without it
          Logger.warning(
            "Failed to query Servarr queue for #{torrent.hash}: #{inspect(reason)} - skipping validation"
          )

          {:ok, torrent}
        end
    end
  end

  # Fire-and-forget refresh of Servarr's monitored downloads
  # This tells Sonarr/Radarr to re-check the download client status
  defp trigger_servarr_refresh(%Torrent{servarr_url: nil}), do: :ok
  defp trigger_servarr_refresh(%Torrent{servarr_api_key: nil}), do: :ok

  defp trigger_servarr_refresh(torrent) do
    client = ServarrClient.new(torrent.servarr_url, torrent.servarr_api_key)

    case ServarrClient.refresh_monitored_downloads(client) do
      :ok ->
        Logger.debug("Triggered RefreshMonitoredDownloads for #{torrent.hash}")

      {:error, reason} ->
        Logger.warning("Failed to trigger RefreshMonitoredDownloads: #{inspect(reason)}")
    end

    :ok
  end

  # Trigger Servarr refresh and wait for it to complete
  # This ensures Sonarr's queue is updated before we query it
  defp trigger_servarr_refresh_and_wait(%Torrent{servarr_url: nil}), do: {:error, :no_url}
  defp trigger_servarr_refresh_and_wait(%Torrent{servarr_api_key: nil}), do: {:error, :no_api_key}

  defp trigger_servarr_refresh_and_wait(torrent) do
    client = ServarrClient.new(torrent.servarr_url, torrent.servarr_api_key)

    Logger.debug("Triggering RefreshMonitoredDownloads and waiting for #{torrent.hash}")

    case ServarrClient.refresh_monitored_downloads_and_wait(client,
           timeout: 30_000,
           poll_interval: 500
         ) do
      :ok ->
        Logger.debug("RefreshMonitoredDownloads completed for #{torrent.hash}")
        # Wait a bit for queue to be fully updated after command completes
        # The command status showing "completed" doesn't mean the queue data is immediately available
        Process.sleep(2000)
        Logger.debug("Queue should now be updated for #{torrent.hash}")
        :ok

      {:error, reason} ->
        Logger.warning("RefreshMonitoredDownloads failed for #{torrent.hash}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  # Notifies Servarr (Sonarr/Radarr) that a download has failed validation
  # This triggers the auto-redownload mechanism by calling the queue DELETE endpoint
  # with blocklist=true, which marks the release as failed and starts a new search
  defp notify_servarr_of_failure(%Torrent{servarr_url: nil}, _reason), do: :ok
  defp notify_servarr_of_failure(%Torrent{servarr_api_key: nil}, _reason), do: :ok

  defp notify_servarr_of_failure(torrent, reason) do
    unless Aria2Debrid.Config.notify_servarr_on_failure?() do
      Logger.debug("Servarr failure notification disabled, skipping for #{torrent.hash}")
      :ok
    else
      client = ServarrClient.new(torrent.servarr_url, torrent.servarr_api_key)

      opts = [
        blocklist: Aria2Debrid.Config.servarr_blocklist_on_failure?(),
        search: Aria2Debrid.Config.servarr_search_on_failure?()
      ]

      case ServarrClient.mark_download_as_failed(client, torrent.hash, opts) do
        {:ok, 0} ->
          Logger.debug(
            "No queue items found in Servarr for #{torrent.hash}, cannot trigger auto-redownload"
          )

        {:ok, count} ->
          Logger.info(
            "Marked #{count} queue item(s) as failed in Servarr for #{torrent.hash}: #{reason} " <>
              "(blocklist: #{opts[:blocklist]}, search: #{opts[:search]})"
          )

        {:error, err} ->
          Logger.warning(
            "Failed to notify Servarr of failure for #{torrent.hash}: #{inspect(err)}"
          )
      end

      :ok
    end
  end

  # Cleans up Real-Debrid torrent when a download fails
  # This frees up RD resources and slots immediately rather than waiting
  # for Sonarr to call aria2.remove (which may not happen depending on settings)
  # Runs synchronously to ensure cleanup completes before process exits
  defp cleanup_real_debrid_on_failure(torrent) do
    Logger.debug(
      "Starting RD cleanup for failed torrent #{torrent.hash} (RD ID: #{torrent.rd_id})"
    )

    try do
      client = get_rd_client()
      Logger.debug("RD client created, calling Delete.delete for RD ID: #{torrent.rd_id}")

      case RealDebrid.Api.Delete.delete(client, torrent.rd_id) do
        :ok ->
          Logger.info(
            "✓ Successfully deleted failed torrent #{torrent.hash} (RD ID: #{torrent.rd_id}) from Real-Debrid"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "✗ Failed to auto-delete torrent #{torrent.hash} (RD ID: #{torrent.rd_id}) from Real-Debrid: #{inspect(reason)}"
          )

          {:error, reason}
      end
    rescue
      e ->
        Logger.error(
          "✗ Exception while auto-deleting torrent #{torrent.hash} (RD ID: #{torrent.rd_id}) from Real-Debrid: #{inspect(e)}"
        )

        Logger.error("Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
        {:error, e}
    end
  end
end

defmodule ProcessingQueue.Validators.MediaValidator do
  @moduledoc """
  Validates media files using FFprobe with concurrent processing.

  Wraps the `MediaValidator` app to provide a consistent interface
  for the validation pipeline. Validates each selected video file
  via Real-Debrid streaming URLs using `Task.async_stream/3` for
  concurrent validation of multiple files.

  ## Validation Checks

  For each video file:
  - Filename doesn't contain "sample"
  - Has video stream (if required)
  - Has audio stream (if required)
  - Duration >= minimum (default 10 minutes, to filter samples)

  ## Concurrency

  Files are validated concurrently using `Task.async_stream/3` with:
  - Max concurrency: capped at 8 concurrent files (avoids RD CDN rate limiting)
  - Timeout: 120 seconds per file (handles network delays + FFprobe processing)
  - Failed tasks are killed on timeout

  This provides fast validation for multi-file torrents while avoiding
  Real-Debrid CDN rate limiting and connection timeouts.

  ## Usage

      case MediaValidator.validate(torrent) do
        :ok -> # All files valid
        {:skip, reason} -> # Validation skipped (disabled)
        {:error, reason} -> # Validation failed
      end
  """

  require Logger

  alias ProcessingQueue.{FileSelector, RDPoller, RetryPolicy, Torrent}

  @doc """
  Validates media files for a torrent.

  ## Parameters
    - `torrent` - Torrent struct with selected files

  ## Returns
    - `:ok` - All files passed validation
    - `{:skip, reason}` - Validation skipped (disabled by config)
    - `{:error, reason}` - Validation failed for one or more files
  """
  @spec validate(Torrent.t()) :: :ok | {:skip, String.t()} | {:error, term()}
  def validate(%Torrent{} = torrent) do
    if Aria2Debrid.Config.media_validation_enabled?() do
      do_validate(torrent)
    else
      Logger.debug("Media validation disabled by config")
      {:skip, "Media validation disabled"}
    end
  end

  @doc """
  Validates a single file via URL.

  ## Parameters
    - `url` - Streaming URL for the file
    - `filename` - Original filename (for sample detection)
    - `opts` - Validation options

  ## Returns
    - `:ok` - File passed validation
    - `{:error, reason}` - Validation failed
  """
  @spec validate_url(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_url(url, filename, opts \\ []) do
    MediaValidator.validate_url(url, Keyword.put(opts, :filename, filename))
  end

  # Private functions

  defp do_validate(%Torrent{files: files, rd_id: rd_id, hash: hash} = torrent)
       when is_list(files) do
    video_files = get_selected_video_files(files)

    if Enum.empty?(video_files) do
      Logger.warning("[#{hash}] No video files to validate")
      {:error, "No video files to validate"}
    else
      validate_files(video_files, rd_id, torrent)
    end
  end

  defp do_validate(%Torrent{hash: hash}) do
    Logger.warning("[#{hash}] No files available for media validation")
    {:error, "No files available"}
  end

  defp get_selected_video_files(files) do
    files
    |> Enum.filter(&FileSelector.selected?/1)
    |> Enum.filter(&FileSelector.video_file?/1)
  end

  defp validate_files(video_files, rd_id, torrent) do
    Logger.debug(
      "[#{torrent.hash}] Starting concurrent validation of #{length(video_files)} files"
    )

    video_files
    |> Task.async_stream(
      fn file -> validate_single_file(file, rd_id, torrent) end,
      max_concurrency: min(8, System.schedulers_online()),
      timeout: 120_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok ->
        {:cont, :ok}

      {:ok, {:error, reason}}, _ ->
        {:halt, {:error, reason}}

      {:exit, reason}, _ ->
        Logger.error("[#{torrent.hash}] Validation task crashed: #{inspect(reason)}")
        {:halt, {:error, {:validation_timeout, reason}}}
    end)
    |> case do
      :ok ->
        Logger.info("[#{torrent.hash}] Media validation passed for #{length(video_files)} files")
        :ok

      error ->
        error
    end
  end

  defp validate_single_file(file, rd_id, torrent) do
    filename = get_filename(file)
    hash = torrent.hash

    Logger.debug("[#{hash}] Validating media file: #{filename}")

    # First check by filename (fast, no network)
    case check_not_sample_by_name(filename) do
      :ok ->
        # Get streaming URL and validate with FFprobe
        validate_via_streaming(file, rd_id, torrent)

      {:error, _} = error ->
        error
    end
  end

  defp validate_via_streaming(file, rd_id, torrent) do
    filename = get_filename(file)
    hash = torrent.hash

    # Get the streaming link from Real-Debrid with retry
    case get_streaming_link_with_retry(file, rd_id, torrent) do
      {:ok, url, _filename} ->
        Logger.debug("[#{hash}] Got streaming URL for #{filename}")

        # Validate with retry (FFprobe can fail on network issues)
        case validate_url_with_retry(url, filename, hash) do
          :ok ->
            Logger.debug("[#{hash}] Media validation passed: #{filename}")
            :ok

          {:error, reason} ->
            Logger.warning(
              "[#{hash}] Media validation failed for #{filename}: #{inspect(reason)}"
            )

            {:error, {:media_validation_failed, filename, reason}}
        end

      {:error, reason} ->
        Logger.warning(
          "[#{hash}] Failed to get streaming link for #{filename}: #{inspect(reason)}"
        )

        {:error, {:streaming_link_failed, filename, reason}}
    end
  end

  defp validate_url_with_retry(url, filename, hash) do
    RetryPolicy.with_retries(
      fn -> MediaValidator.validate_url(url, enabled: true, filename: filename) end,
      max_retries: 3,
      base_delay: 1_000,
      max_delay: 5_000,
      on_retry: fn attempt ->
        Logger.info(
          "[#{hash}] Retrying FFprobe validation for #{filename} (attempt #{attempt}/3)"
        )
      end
    )
  end

  defp get_streaming_link_with_retry(file, rd_id, torrent) do
    RetryPolicy.with_retries(
      fn -> get_streaming_link(file, rd_id, torrent) end,
      max_retries: 3,
      base_delay: 1_000,
      max_delay: 5_000,
      on_retry: fn attempt ->
        filename = get_filename(file)

        Logger.info(
          "[#{torrent.hash}] Retrying RD unrestrict link for #{filename} (attempt #{attempt}/3)"
        )
      end
    )
  end

  defp get_streaming_link(file, rd_id, torrent) do
    client = RDPoller.get_client()

    if client == nil do
      {:error, :missing_rd_token}
    else
      # Get link from file or fetch from RD
      case Map.get(file, "link") || Map.get(file, :link) do
        nil ->
          # Need to fetch from RD
          fetch_link_from_rd(client, file, rd_id, torrent)

        link when is_binary(link) and link != "" ->
          # Unrestrict the link
          RDPoller.unrestrict_link(client, link)

        _ ->
          fetch_link_from_rd(client, file, rd_id, torrent)
      end
    end
  end

  defp fetch_link_from_rd(client, file, rd_id, torrent) do
    file_id = get_file_id(file)

    case RDPoller.get_torrent_links(client, rd_id) do
      {:ok, links} ->
        # Find matching link for this file
        case find_link_for_file(links, file_id, torrent) do
          {:ok, link} ->
            RDPoller.unrestrict_link(client, link)

          error ->
            error
        end

      error ->
        error
    end
  end

  defp find_link_for_file(links, file_id, torrent) when is_list(links) do
    if Enum.empty?(links) do
      {:error, :no_links_available}
    else
      # Real-Debrid returns links in the same order as selected files
      # Get all selected files and find the index of our file
      selected_files =
        torrent.files
        |> Enum.filter(&(&1["selected"] == 1))
        |> Enum.sort_by(&get_file_id/1)

      file_index = Enum.find_index(selected_files, fn f -> get_file_id(f) == file_id end)

      case file_index do
        nil ->
          Logger.warning("[#{torrent.hash}] File ID #{file_id} not found in selected files")
          {:error, :file_not_selected}

        index when index < length(links) ->
          link = Enum.at(links, index)

          Logger.debug(
            "[#{torrent.hash}] Matched file ID #{file_id} to link at position #{index}"
          )

          {:ok, link}

        index ->
          Logger.warning(
            "[#{torrent.hash}] File index #{index} out of bounds for #{length(links)} links (file_id=#{file_id})"
          )

          # Fallback: use first link if only one available
          if length(links) == 1 do
            Logger.debug("[#{torrent.hash}] Using single available link as fallback")
            {:ok, List.first(links)}
          else
            {:error, :link_index_out_of_bounds}
          end
      end
    end
  end

  defp find_link_for_file(_, _, _), do: {:error, :no_links_available}

  defp check_not_sample_by_name(filename) do
    if MediaValidator.is_sample_by_name?(filename) do
      {:error, {:sample_file, filename}}
    else
      :ok
    end
  end

  defp get_filename(file) when is_map(file) do
    Map.get(file, "path") || Map.get(file, :path) ||
      Map.get(file, "name") || Map.get(file, :name) || "unknown"
  end

  defp get_file_id(file) when is_map(file) do
    Map.get(file, "id") || Map.get(file, :id)
  end
end

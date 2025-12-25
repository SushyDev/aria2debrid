defmodule ProcessingQueue.Validators.MediaValidator do
  @moduledoc """
  Validates media files using FFprobe.

  Wraps the `MediaValidator` app to provide a consistent interface
  for the validation pipeline. Validates each selected video file
  via Real-Debrid streaming URLs.

  ## Validation Checks

  For each video file:
  - File size >= minimum (default 500MB)
  - Filename doesn't contain "sample"
  - Has video stream (if required)
  - Has audio stream (if required)
  - Duration >= minimum (default 5 minutes, to filter samples)

  ## Usage

      case MediaValidator.validate(torrent) do
        :ok -> # All files valid
        {:skip, reason} -> # Validation skipped (disabled)
        {:error, reason} -> # Validation failed
      end
  """

  require Logger

  alias ProcessingQueue.{FileSelector, RDPoller, Torrent}

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
    results =
      video_files
      |> Enum.map(fn file ->
        validate_single_file(file, rd_id, torrent)
      end)

    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      nil ->
        Logger.info("[#{torrent.hash}] Media validation passed for #{length(video_files)} files")
        :ok

      {:error, reason} ->
        {:error, reason}
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

    # Get the streaming link from Real-Debrid
    case get_streaming_link(file, rd_id, torrent) do
      {:ok, url, _filename} ->
        Logger.debug("[#{hash}] Got streaming URL for #{filename}")

        case MediaValidator.validate_url(url, enabled: true) do
          :ok ->
            Logger.debug("[#{hash}] Media validation passed: #{filename}")
            :ok

          {:error, reason} ->
            Logger.warning("[#{hash}] Media validation failed for #{filename}: #{inspect(reason)}")
            {:error, {:media_validation_failed, filename, reason}}
        end

      {:error, reason} ->
        Logger.warning("[#{hash}] Failed to get streaming link for #{filename}: #{inspect(reason)}")
        {:error, {:streaming_link_failed, filename, reason}}
    end
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
          {:ok, link} -> RDPoller.unrestrict_link(client, link)
          error -> error
        end

      error ->
        error
    end
  end

  defp find_link_for_file(links, file_id, torrent) when is_list(links) do
    filename = get_filename_by_id(torrent.files, file_id)

    # Links from RD are ordered by file selection
    # Try to match by filename or position
    matching_link =
      Enum.find(links, fn link ->
        link_filename = link |> URI.parse() |> Map.get(:path, "") |> Path.basename()
        String.ends_with?(link_filename, Path.basename(filename || ""))
      end)

    case matching_link do
      nil when links != [] ->
        # Fallback to first link if only one
        {:ok, List.first(links)}

      nil ->
        {:error, :no_matching_link}

      link ->
        {:ok, link}
    end
  end

  defp find_link_for_file(_, _, _), do: {:error, :no_links_available}

  defp get_filename_by_id(files, file_id) when is_list(files) do
    file = Enum.find(files, fn f -> get_file_id(f) == file_id end)
    if file, do: get_filename(file), else: nil
  end

  defp get_filename_by_id(_, _), do: nil

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

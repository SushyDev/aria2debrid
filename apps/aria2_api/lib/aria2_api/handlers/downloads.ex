defmodule Aria2Api.Handlers.Downloads do
  @moduledoc """
  Handles aria2 download management RPC methods.

  Maps ProcessingQueue operations to aria2 XML-RPC methods. Supports multi-tenant
  filtering via secret token mapping or legacy credential passing via `dir` option.
  """

  require Logger

  alias Aria2Api.GidRegistry
  alias ProcessingQueue.Torrent

  # aria2 error codes
  @error_unknown 1
  @error_http 24

  @doc """
  Handles aria2.addUri - Add download by magnet URI.

  Credentials must be provided via SecretToken (url|api_key format).
  """
  def add_uri(params, servarr_credentials \\ nil)

  def add_uri([uris | rest], servarr_credentials) when is_list(uris) do
    _options = List.first(rest) || %{}

    case Enum.find(uris, &String.starts_with?(&1, "magnet:")) do
      nil ->
        {:error, -32602, "No valid magnet URI provided"}

      magnet ->
        opts =
          case servarr_credentials do
            {servarr_url, servarr_api_key} ->
              [servarr_url: servarr_url, servarr_api_key: servarr_api_key]

            nil ->
              []
          end

        case ProcessingQueue.add_magnet(magnet, opts) do
          {:ok, hash} ->
            gid = GidRegistry.register(hash)
            Logger.info("Added download: gid=#{gid} hash=#{hash}")
            {:ok, gid}

          {:error, reason} ->
            Logger.error("Failed to add download: #{inspect(reason)}")
            {:error, @error_unknown, "Failed to add download: #{inspect(reason)}"}
        end
    end
  end

  def add_uri(_, _), do: {:error, -32602, "Invalid params"}

  @doc """
  Handles aria2.addTorrent - Add download by torrent file.

  Credentials must be provided via SecretToken (url|api_key format).

  Note: The torrent data is already decoded from base64 by the XML-RPC parser.
  The XmlRpc module automatically decodes <base64> elements, so we receive
  raw binary torrent data here, not base64-encoded string.
  """
  def add_torrent(params, servarr_credentials \\ nil)

  def add_torrent([torrent_data | _rest], servarr_credentials) when is_binary(torrent_data) do
    # torrent_data is already raw binary (decoded by XML-RPC parser from <base64> element)
    opts =
      case servarr_credentials do
        {servarr_url, servarr_api_key} ->
          [servarr_url: servarr_url, servarr_api_key: servarr_api_key]

        nil ->
          []
      end

    case ProcessingQueue.add_torrent_file(torrent_data, opts) do
      {:ok, hash} ->
        gid = GidRegistry.register(hash)
        Logger.info("Added torrent file: gid=#{gid} hash=#{hash}")
        {:ok, gid}

      {:error, reason} ->
        Logger.error("Failed to add torrent file: #{inspect(reason)}")
        {:error, @error_unknown, "Failed to add torrent: #{inspect(reason)}"}
    end
  end

  def add_torrent(_params, _credentials) do
    {:error, -32602, "Invalid params: expected [torrent_base64, uris, options]"}
  end

  @doc """
  Handles aria2.tellStatus - Get download status by GID.

  params: [gid, keys]
  - gid: Download GID
  - keys: Optional array of keys to return (returns all if empty)

  Returns: Download status object
  """
  def tell_status([gid | rest]) when is_binary(gid) do
    keys = List.first(rest) || []

    case GidRegistry.lookup_hash(gid) do
      {:ok, hash} ->
        case ProcessingQueue.get_torrent(hash) do
          {:ok, torrent} ->
            status = torrent_to_aria2(torrent, gid)
            {:ok, filter_keys(status, keys)}

          {:error, :not_found} ->
            GidRegistry.unregister(gid)
            {:error, 1, "Download not found: #{gid}"}
        end

      {:error, :not_found} ->
        {:error, 1, "Download not found: #{gid}"}
    end
  end

  def tell_status(_), do: {:error, -32602, "Invalid params"}

  # States that map to aria2 status="active"
  @active_states [:waiting_download, :validating_count, :validating_media, :validating_path]

  # States that map to aria2 status="waiting"
  @waiting_states [
    :pending,
    :adding_rd,
    :waiting_metadata,
    :selecting_files,
    :refreshing_info,
    :fetching_queue
  ]

  @doc """
  Handles aria2.tellActive - List active downloads.

  Returns torrents that map to aria2 status="active" (downloading/validating states).
  Also includes warning failures which appear as stalled active downloads.
  Filters by Servarr instance using grabbed history (infohash matching).
  Returns empty list if no credentials provided.
  """
  def tell_active(params, servarr_credentials \\ nil) do
    keys = List.first(params) || []

    all_torrents = ProcessingQueue.list_torrents()

    # Include active states AND warning failures (which report as status="active")
    active_torrents =
      Enum.filter(all_torrents, fn t ->
        t.state in @active_states or (t.state == :failed and t.failure_type == :warning)
      end)

    filtered_torrents = filter_by_servarr(active_torrents, servarr_credentials)

    Logger.debug(
      "tellActive: #{length(all_torrents)} total, #{length(active_torrents)} active/warning, #{length(filtered_torrents)} after filtering"
    )

    downloads =
      filtered_torrents
      |> Enum.map(fn torrent ->
        gid = get_or_create_gid(torrent.hash)
        status = torrent_to_aria2(torrent, gid)

        Logger.debug(
          "tellActive: #{torrent.hash} state=#{torrent.state} -> aria2_status=#{status["status"]}"
        )

        filter_keys(status, keys)
      end)

    {:ok, downloads}
  end

  @doc """
  Handles aria2.tellWaiting - List waiting downloads.

  Returns torrents that map to aria2 status="waiting" (queued/pending states).
  Filters by Servarr instance using grabbed history (infohash matching).
  Returns empty list if no credentials provided.
  """
  def tell_waiting(params, servarr_credentials \\ nil) do
    {offset, num, keys} = parse_pagination_params(params)

    waiting_torrents =
      ProcessingQueue.list_torrents()
      |> Enum.filter(fn t -> t.state in @waiting_states end)

    filtered_torrents = filter_by_servarr(waiting_torrents, servarr_credentials)

    Logger.debug(
      "tellWaiting: #{length(waiting_torrents)} waiting, #{length(filtered_torrents)} after filtering (offset=#{offset}, num=#{num})"
    )

    downloads =
      filtered_torrents
      |> Enum.drop(offset)
      |> Enum.take(num)
      |> Enum.map(fn torrent ->
        gid = get_or_create_gid(torrent.hash)
        status = torrent_to_aria2(torrent, gid)
        filter_keys(status, keys)
      end)

    {:ok, downloads}
  end

  @doc """
  Handles aria2.tellStopped - List stopped downloads.

  Returns torrents that map to aria2 status="complete" or status="error".
  Warning failures are excluded (they appear in tellActive as stalled).
  Filters by Servarr instance using grabbed history (infohash matching).
  Returns empty list if no credentials provided.
  """
  def tell_stopped(params, servarr_credentials \\ nil) do
    {offset, num, keys} = parse_pagination_params(params)

    all_torrents = ProcessingQueue.list_torrents()

    # Include success and failed states, but exclude warning failures (they go to tellActive)
    stopped_torrents =
      Enum.filter(all_torrents, fn t ->
        t.state == :success or (t.state == :failed and t.failure_type != :warning)
      end)

    filtered_torrents = filter_by_servarr(stopped_torrents, servarr_credentials)

    Logger.debug(
      "tellStopped: #{length(all_torrents)} total, #{length(stopped_torrents)} stopped, #{length(filtered_torrents)} after filtering (offset=#{offset}, num=#{num})"
    )

    downloads =
      filtered_torrents
      |> Enum.drop(offset)
      |> Enum.take(num)
      |> Enum.map(fn torrent ->
        gid = get_or_create_gid(torrent.hash)
        status = torrent_to_aria2(torrent, gid)

        if status["status"] == "error" do
          Logger.debug(
            "tellStopped: #{torrent.hash} state=#{torrent.state} failure_type=#{torrent.failure_type} -> aria2_status=#{status["status"]} errorCode=#{status["errorCode"]}"
          )
        else
          Logger.debug(
            "tellStopped: #{torrent.hash} state=#{torrent.state} -> aria2_status=#{status["status"]}"
          )
        end

        filter_keys(status, keys)
      end)

    {:ok, downloads}
  end

  @doc """
  Handles aria2.remove - Remove a download.

  params: [gid]

  Returns: GID of removed download
  """
  def remove([gid]) when is_binary(gid) do
    case GidRegistry.lookup_hash(gid) do
      {:ok, hash} ->
        case ProcessingQueue.remove_torrent(hash) do
          :ok ->
            GidRegistry.unregister(gid)
            Logger.info("Removed download: gid=#{gid}")
            {:ok, gid}

          {:error, reason} ->
            {:error, @error_unknown, "Failed to remove: #{inspect(reason)}"}
        end

      {:error, :not_found} ->
        {:error, 1, "Download not found: #{gid}"}
    end
  end

  def remove(_), do: {:error, -32602, "Invalid params"}

  @doc """
  Handles aria2.forceRemove - Force remove a download.
  """
  def force_remove(params), do: remove(params)

  @doc """
  Handles aria2.removeDownloadResult - Remove completed/error download result.

  params: [gid]

  Returns: "OK" on success
  """
  def remove_download_result([gid]) when is_binary(gid) do
    case GidRegistry.lookup_hash(gid) do
      {:ok, hash} ->
        Logger.info("Radarr/Sonarr called removeDownloadResult for gid=#{gid} hash=#{hash}")

        case ProcessingQueue.remove_torrent(hash) do
          :ok ->
            GidRegistry.unregister(gid)
            Logger.info("Successfully removed download result: gid=#{gid} hash=#{hash}")
            {:ok, "OK"}

          {:error, reason} ->
            Logger.warning(
              "Failed to remove download result for gid=#{gid} hash=#{hash}: #{inspect(reason)}, cleaning up GID anyway"
            )

            GidRegistry.unregister(gid)
            {:ok, "OK"}
        end

      {:error, :not_found} ->
        Logger.debug(
          "removeDownloadResult called for unknown gid=#{gid} (already removed or never existed)"
        )

        {:ok, "OK"}
    end
  end

  def remove_download_result(_), do: {:error, -32602, "Invalid params"}

  @doc """
  Handles aria2.pause - Pause a download.

  params: [gid]

  Returns: GID of paused download
  """
  def pause([gid]) when is_binary(gid) do
    case GidRegistry.lookup_hash(gid) do
      {:ok, hash} ->
        case ProcessingQueue.pause_torrent(hash) do
          :ok ->
            Logger.info("Paused download: gid=#{gid}")
            {:ok, gid}

          {:error, reason} ->
            {:error, @error_unknown, "Failed to pause: #{inspect(reason)}"}
        end

      {:error, :not_found} ->
        {:error, 1, "Download not found: #{gid}"}
    end
  end

  def pause(_), do: {:error, -32602, "Invalid params"}

  @doc """
  Handles aria2.unpause - Resume a paused download.

  params: [gid]

  Returns: GID of resumed download
  """
  def unpause([gid]) when is_binary(gid) do
    case GidRegistry.lookup_hash(gid) do
      {:ok, hash} ->
        case ProcessingQueue.resume_torrent(hash) do
          :ok ->
            Logger.info("Resumed download: gid=#{gid}")
            {:ok, gid}

          {:error, reason} ->
            {:error, @error_unknown, "Failed to resume: #{inspect(reason)}"}
        end

      {:error, :not_found} ->
        {:error, 1, "Download not found: #{gid}"}
    end
  end

  def unpause(_), do: {:error, -32602, "Invalid params"}

  # Private functions

  defp get_or_create_gid(hash) do
    case GidRegistry.lookup_gid(hash) do
      {:ok, gid} -> gid
      {:error, :not_found} -> GidRegistry.register(hash)
    end
  end

  defp parse_pagination_params([offset, num | rest])
       when is_integer(offset) and is_integer(num) do
    keys = List.first(rest) || []
    {offset, num, keys}
  end

  defp parse_pagination_params([offset, num | rest]) when is_binary(offset) and is_binary(num) do
    {String.to_integer(offset), String.to_integer(num), List.first(rest) || []}
  end

  defp parse_pagination_params(_), do: {0, 1000, []}

  defp filter_keys(status, []), do: status
  defp filter_keys(status, keys), do: Map.take(status, keys)

  @doc """
  Converts a ProcessingQueue.Torrent to aria2 status format.
  """
  def torrent_to_aria2(%Torrent{} = torrent, gid) do
    {status, error_code, error_message} = get_aria2_status(torrent)
    total_length = torrent.size || 0
    completed_length = calculate_completed_length(torrent)

    base = %{
      "gid" => gid,
      "status" => status,
      "totalLength" => to_string(total_length),
      "completedLength" => to_string(completed_length),
      "uploadLength" => "0",
      "downloadSpeed" => "0",
      "uploadSpeed" => "0",
      "connections" => "0",
      "numSeeders" => "0",
      "seeder" => "false",
      "dir" => torrent.save_path || Aria2Debrid.Config.save_path(),
      "files" => build_files(torrent),
      "bittorrent" => build_bittorrent_info(torrent),
      "infoHash" => String.upcase(torrent.hash)
    }

    if status == "error" do
      Logger.debug(
        "torrent_to_aria2: #{torrent.hash} failure_type=#{inspect(torrent.failure_type)} -> errorCode=#{error_code}"
      )

      base
      |> Map.put("errorCode", to_string(error_code))
      |> Map.put("errorMessage", error_message)
    else
      base
    end
  end

  defp get_aria2_status(%Torrent{state: :success}), do: {"complete", nil, nil}

  defp get_aria2_status(%Torrent{state: :failed, failure_type: :validation, error: error}) do
    {"error", @error_http, error || "Validation failed"}
  end

  defp get_aria2_status(%Torrent{state: :failed, failure_type: :warning, error: error}) do
    {"active", nil, error || "Warning"}
  end

  defp get_aria2_status(%Torrent{state: :failed, error: error}) do
    {"error", @error_unknown, error || "Download failed"}
  end

  defp get_aria2_status(%Torrent{state: state})
       when state in [
              :pending,
              :adding_rd,
              :waiting_metadata,
              :selecting_files,
              :refreshing_info,
              :fetching_queue
            ] do
    {"waiting", nil, nil}
  end

  defp get_aria2_status(%Torrent{state: state})
       when state in [:waiting_download, :validating_count, :validating_media, :validating_path] do
    {"active", nil, nil}
  end

  defp get_aria2_status(%Torrent{}), do: {"waiting", nil, nil}

  defp calculate_completed_length(%Torrent{state: :success, size: size}), do: size

  # Validation states should show minimal progress (1 byte) to appear in Sonarr Activity
  # but not 100% to prevent "Downloaded - Waiting to Import" status
  # Sonarr filters out downloads with 0% progress from the Activity view
  defp calculate_completed_length(%Torrent{state: state, size: size})
       when state in [:validating_count, :validating_media, :validating_path] and size > 0 do
    1
  end

  defp calculate_completed_length(%Torrent{size: size, progress: progress}) when size > 0 do
    round(size * progress / 100.0)
  end

  defp calculate_completed_length(_), do: 0

  defp build_files(%Torrent{files: nil} = torrent) do
    # No files metadata yet - return a placeholder to prevent Sonarr crash
    # Sonarr calls GetLongestCommonPath which requires at least one file
    build_placeholder_files(torrent)
  end

  defp build_files(%Torrent{files: files, save_path: save_path} = torrent) do
    base_path = save_path || Aria2Debrid.Config.save_path()

    selected_files =
      files
      |> Enum.filter(fn file -> file["selected"] == 1 end)
      |> Enum.with_index(1)
      |> Enum.map(fn {file, index} ->
        path = file["path"] || ""
        size = file["bytes"] || 0

        %{
          "index" => to_string(index),
          "path" => Path.join(base_path, path),
          "length" => to_string(size),
          "completedLength" => to_string(size),
          "selected" => "true",
          "uris" => []
        }
      end)

    # If no files selected, return placeholder to prevent Sonarr crash
    # This can happen during early stages before file selection completes
    if Enum.empty?(selected_files) do
      build_placeholder_files(torrent)
    else
      selected_files
    end
  end

  defp build_placeholder_files(%Torrent{name: name, hash: hash, save_path: save_path, size: size}) do
    base_path = save_path || Aria2Debrid.Config.save_path()
    # Use torrent name or hash as placeholder filename
    filename = name || hash

    [
      %{
        "index" => "1",
        "path" => Path.join(base_path, filename),
        "length" => to_string(size || 0),
        "completedLength" => to_string(size || 0),
        "selected" => "true",
        "uris" => []
      }
    ]
  end

  defp build_bittorrent_info(%Torrent{name: name, hash: hash, files: files, size: size}) do
    # Build file list in torrent metainfo format
    file_list =
      if files && Enum.any?(files) do
        files
        |> Enum.map(fn file ->
          %{
            "length" => file["bytes"] || 0,
            "path" => String.split(file["path"] || "", "/")
          }
        end)
      else
        []
      end

    info = %{
      "name" => name || hash,
      "pieceLength" => 16384
    }

    # Add files or length based on whether it's multi-file or single-file
    info =
      if Enum.empty?(file_list) do
        # Single file torrent or no metadata yet
        Map.put(info, "length", size || 0)
      else
        # Multi-file torrent
        Map.put(info, "files", file_list)
      end

    %{
      "announceList" => [],
      "comment" => "",
      "creationDate" => 0,
      "mode" => if(Enum.empty?(file_list), do: "single", else: "multi"),
      "info" => info
    }
  end

  defp build_bittorrent_info(%Torrent{name: name, hash: hash}) do
    %{
      "announceList" => [],
      "comment" => "",
      "creationDate" => 0,
      "mode" => "multi",
      "info" => %{
        "name" => name || hash,
        "pieceLength" => 16384,
        "files" => []
      }
    }
  end

  @doc """
  Filters torrents by Servarr instance using grabbed history infohash matching.
  """
  def filter_by_servarr(_torrents, nil) do
    Logger.error("No Servarr credentials provided - this is required for multi-tenant security")
    []
  end

  def filter_by_servarr(torrents, {servarr_url, servarr_api_key}) do
    client = ServarrClient.new(servarr_url, servarr_api_key)

    case ServarrClient.get_grabbed_download_ids(client) do
      {:ok, grabbed_hashes} ->
        filtered =
          Enum.filter(torrents, fn torrent ->
            MapSet.member?(grabbed_hashes, String.downcase(torrent.hash))
          end)

        Logger.debug(
          "Filtered torrents by servarr history (#{servarr_url}): #{length(torrents)} -> #{length(filtered)}"
        )

        filtered

      {:error, reason} ->
        Logger.error(
          "Failed to fetch Servarr history for filtering (#{servarr_url}): #{inspect(reason)} - returning empty list"
        )

        []
    end
  end
end

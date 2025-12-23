defmodule Aria2Api.Handlers.Downloads do
  @moduledoc """
  Handles aria2 download management RPC methods.

  Maps ProcessingQueue operations to aria2 JSON-RPC methods.

  ## Servarr Credential Passing

  Since aria2's RPC protocol doesn't support passing custom metadata,
  we use the `dir` option to pass Servarr credentials for episode count
  detection and failure notifications.

  In Sonarr/Radarr, configure the download client's directory as:

      http://sonarr:8989|YOUR_API_KEY

  The format is: `servarr_url|api_key`

  The pipe character is used as delimiter since URLs contain colons.
  If no credentials are provided, episode count validation is skipped.
  """

  require Logger

  alias Aria2Api.GidRegistry
  alias ProcessingQueue.Torrent

  # aria2 error codes
  @error_unknown 1
  @error_http 24

  @doc """
  Handles aria2.addUri - Add download by URI.

  params: [uris, options]
  - uris: Array of URIs (we only support magnet links)
  - options: Optional download options
    - "dir": Can contain Servarr credentials in format "url|api_key"

  Returns: GID of the new download
  """
  def add_uri([uris | rest]) when is_list(uris) do
    options = List.first(rest) || %{}

    case Enum.find(uris, &String.starts_with?(&1, "magnet:")) do
      nil ->
        {:error, -32602, "No valid magnet URI provided"}

      magnet ->
        {servarr_url, servarr_api_key} = parse_servarr_credentials(options)

        opts =
          if servarr_url && servarr_api_key do
            Logger.debug("Extracted Servarr credentials from dir option: #{servarr_url}")
            [servarr_url: servarr_url, servarr_api_key: servarr_api_key]
          else
            Logger.debug("No Servarr credentials in dir option")
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

  def add_uri(_), do: {:error, -32602, "Invalid params"}

  @doc """
  Handles aria2.addTorrent - Add download by torrent file.

  params: [torrent_base64, uris, options]
  - torrent_base64: Base64 encoded torrent file
  - uris: Optional array of URIs (for web seeding, ignored)
  - options: Optional download options
    - "dir": Can contain Servarr credentials in format "url|api_key"

  Returns: GID of the new download
  """
  def add_torrent([torrent_base64 | rest]) when is_binary(torrent_base64) do
    case Base.decode64(torrent_base64) do
      {:ok, torrent_data} ->
        options =
          case rest do
            [uris, opts] when is_list(uris) and is_map(opts) -> opts
            [opts] when is_map(opts) -> opts
            _ -> %{}
          end

        {servarr_url, servarr_api_key} = parse_servarr_credentials(options)

        opts =
          if servarr_url && servarr_api_key do
            Logger.debug("Extracted Servarr credentials from dir option: #{servarr_url}")
            [servarr_url: servarr_url, servarr_api_key: servarr_api_key]
          else
            Logger.debug("No Servarr credentials in dir option")
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

      :error ->
        Logger.error("Failed to decode base64 torrent data")
        {:error, -32602, "Invalid base64 encoding for torrent file"}
    end
  end

  def add_torrent(_params) do
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

  @doc """
  Handles aria2.tellActive - List active downloads.

  params: [keys]
  - keys: Optional array of keys to return

  Returns: Array of active download statuses
  """
  def tell_active(params) do
    keys = List.first(params) || []

    all_torrents = ProcessingQueue.list_torrents()
    processing_torrents = Enum.filter(all_torrents, &Torrent.processing?/1)

    Logger.debug(
      "tellActive: #{length(all_torrents)} total torrents, #{length(processing_torrents)} processing"
    )

    downloads =
      processing_torrents
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

  params: [offset, num, keys]
  - offset: Start position
  - num: Number of downloads to return
  - keys: Optional array of keys to return

  Returns: Array of waiting download statuses
  """
  def tell_waiting(params) do
    {offset, num, keys} = parse_pagination_params(params)

    downloads =
      ProcessingQueue.list_torrents()
      |> Enum.filter(fn t -> t.state == :pending end)
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

  params: [offset, num, keys]
  - offset: Start position
  - num: Number of downloads to return
  - keys: Optional array of keys to return

  Returns: Array of stopped download statuses
  """
  def tell_stopped(params) do
    {offset, num, keys} = parse_pagination_params(params)

    all_torrents = ProcessingQueue.list_torrents()
    stopped_torrents = Enum.filter(all_torrents, fn t -> t.state in [:success, :failed] end)

    Logger.debug(
      "tellStopped: #{length(all_torrents)} total torrents, #{length(stopped_torrents)} stopped (offset=#{offset}, num=#{num})"
    )

    downloads =
      stopped_torrents
      |> Enum.drop(offset)
      |> Enum.take(num)
      |> Enum.map(fn torrent ->
        gid = get_or_create_gid(torrent.hash)
        status = torrent_to_aria2(torrent, gid)

        Logger.debug(
          "tellStopped: #{torrent.hash} state=#{torrent.state} -> aria2_status=#{status["status"]}"
        )

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
        case ProcessingQueue.remove_torrent(hash) do
          :ok ->
            GidRegistry.unregister(gid)
            Logger.info("Removed download result: gid=#{gid}")
            {:ok, "OK"}

          {:error, _reason} ->
            GidRegistry.unregister(gid)
            {:ok, "OK"}
        end

      {:error, :not_found} ->
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
      "dir" => Aria2Debrid.Config.save_path(),
      "files" => build_files(torrent),
      "bittorrent" => build_bittorrent_info(torrent),
      "infoHash" => String.upcase(torrent.hash)
    }

    if status == "error" do
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

  defp calculate_completed_length(%Torrent{size: size, progress: progress}) when size > 0 do
    round(size * progress / 100.0)
  end

  defp calculate_completed_length(_), do: 0

  defp build_files(%Torrent{files: nil}), do: []

  defp build_files(%Torrent{files: files, save_path: save_path}) do
    base_path = save_path || Aria2Debrid.Config.save_path()

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
  end

  defp build_bittorrent_info(%Torrent{name: name, hash: hash}) do
    %{
      "announceList" => [],
      "comment" => "",
      "creationDate" => 0,
      "mode" => "multi",
      "info" => %{
        "name" => name || hash
      }
    }
  end

  @doc """
  Parses Servarr credentials from the `dir` option.

  The `dir` option can contain Servarr URL and API key in the format:
  `http://sonarr:8989|YOUR_API_KEY`

  Using pipe (|) as delimiter since URLs contain colons.

  Returns `{servarr_url, servarr_api_key}` or `{nil, nil}` if not found.
  """
  def parse_servarr_credentials(options) when is_map(options) do
    case Map.get(options, "dir") do
      nil ->
        {nil, nil}

      dir when is_binary(dir) ->
        parse_dir_credentials(dir)

      _ ->
        {nil, nil}
    end
  end

  def parse_servarr_credentials(_), do: {nil, nil}

  defp parse_dir_credentials(dir) do
    case split_on_last_pipe(dir) do
      {url, api_key} when byte_size(url) > 0 and byte_size(api_key) > 0 ->
        if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
          {url, api_key}
        else
          Logger.debug("Dir option doesn't look like servarr credentials: #{dir}")
          {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp split_on_last_pipe(string) do
    case :binary.matches(string, "|") do
      [] ->
        {string, ""}

      matches ->
        {pos, _len} = List.last(matches)
        url = binary_part(string, 0, pos)
        api_key = binary_part(string, pos + 1, byte_size(string) - pos - 1)
        {url, api_key}
    end
  end
end

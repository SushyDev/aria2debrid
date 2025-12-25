defmodule Aria2Api.Handlers.System do
  @moduledoc """
  Handles aria2 system RPC methods.

  Provides version info, global stats, and method listing.
  """

  alias ProcessingQueue.Torrent

  @version "1.37.0"

  @doc """
  Handles aria2.getVersion - Get aria2 version info.

  Returns: Version info object
  """
  def get_version do
    {:ok,
     %{
       "version" => @version,
       "enabledFeatures" => [
         "BitTorrent",
         "Firefox3 Cookie",
         "GZip",
         "HTTPS",
         "Message Digest",
         "Metalink",
         "XML-RPC"
       ]
     }}
  end

  @doc """
  Handles aria2.getGlobalStat - Get global download statistics.

  Returns: Global stats object
  """
  def get_global_stat do
    torrents = ProcessingQueue.list_torrents()

    active_count = Enum.count(torrents, &Torrent.processing?/1)
    waiting_count = Enum.count(torrents, fn t -> t.state == :pending end)
    stopped_count = Enum.count(torrents, fn t -> t.state in [:success, :failed] end)

    {:ok,
     %{
       "downloadSpeed" => "0",
       "uploadSpeed" => "0",
       "numActive" => to_string(active_count),
       "numWaiting" => to_string(waiting_count),
       "numStopped" => to_string(stopped_count),
       "numStoppedTotal" => to_string(stopped_count)
     }}
  end

  @doc """
  Handles aria2.getGlobalOption - Get global options.

  Returns: Global options dictionary
  """
  def get_global_option do
    {:ok,
     %{
       "dir" => Aria2Debrid.Config.save_path(),
       "max-concurrent-downloads" => "5",
       "max-connection-per-server" => "1",
       "min-split-size" => "20M",
       "split" => "5",
       "bt-max-peers" => "55",
       "bt-request-peer-speed-limit" => "50K",
       "follow-torrent" => "true",
       "seed-ratio" => "1.0"
     }}
  end

  @doc """
  Handles aria2.getSessionInfo - Get session info.

  Returns: Session info object
  """
  def get_session_info do
    session_id =
      :erlang.system_time(:millisecond)
      |> Integer.to_string()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    {:ok,
     %{
       "sessionId" => session_id
     }}
  end

  @doc """
  Validates Servarr credentials by calling the system/status endpoint.
  Called during Sonarr/Radarr's "Test" button.

  This function always validates credentials, even if they're cached.
  Use `validate_credentials_cached/1` for cached validation.
  """
  def validate_credentials(nil) do
    {:ok, %{"status" => "ok", "message" => "No credentials configured"}}
  end

  def validate_credentials({servarr_url, servarr_api_key}) do
    require Logger

    Logger.info(
      "Validating Servarr credentials: url=#{servarr_url}, api_key=#{String.slice(servarr_api_key, 0..7)}..."
    )

    client = ServarrClient.new(servarr_url, servarr_api_key)

    case ServarrClient.test_connection(client) do
      :ok ->
        Logger.info("✓ Servarr credentials validated: #{servarr_url}")

        # Cache the successful validation
        Aria2Api.CredentialCache.mark_validated({servarr_url, servarr_api_key})

        {:ok,
         %{
           "status" => "ok",
           "message" => "Successfully connected to Servarr",
           "servarrUrl" => servarr_url
         }}

      {:error, reason} ->
        Logger.error("✗ Servarr validation failed: #{servarr_url} - #{inspect(reason)}")

        {:error, 1,
         "Failed to connect to Servarr at #{servarr_url}: #{inspect(reason)}. Check SecretToken format (url|api_key) and ensure Servarr is accessible."}
    end
  end

  @doc """
  Validates Servarr credentials with caching.

  If credentials were previously validated successfully, returns success immediately
  without calling the Servarr API. Otherwise, performs full validation.

  This is used during health checks to avoid repeatedly calling the Servarr API.
  """
  def validate_credentials_cached(nil) do
    {:ok, %{"status" => "ok", "message" => "No credentials configured"}}
  end

  def validate_credentials_cached({servarr_url, servarr_api_key} = creds) do
    require Logger

    if Aria2Api.CredentialCache.validated?(creds) do
      Logger.debug(
        "Servarr credentials already validated (cached): url=#{servarr_url}, api_key=#{String.slice(servarr_api_key, 0..7)}..."
      )

      {:ok,
       %{
         "status" => "ok",
         "message" => "Credentials previously validated (cached)",
         "servarrUrl" => servarr_url
       }}
    else
      # First time validation - perform full check and cache result
      validate_credentials(creds)
    end
  end

  @doc """
  Handles system.listMethods - List available RPC methods.

  Returns: Array of method names
  """
  def list_methods do
    {:ok,
     [
       "aria2.addUri",
       "aria2.addTorrent",
       "aria2.tellStatus",
       "aria2.tellActive",
       "aria2.tellWaiting",
       "aria2.tellStopped",
       "aria2.remove",
       "aria2.forceRemove",
       "aria2.removeDownloadResult",
       "aria2.pause",
       "aria2.unpause",
       "aria2.getGlobalOption",
       "aria2.getGlobalStat",
       "aria2.getVersion",
       "aria2.getSessionInfo",
       "system.multicall",
       "system.listMethods"
     ]}
  end
end

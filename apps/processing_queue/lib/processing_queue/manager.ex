defmodule ProcessingQueue.Manager do
  @moduledoc """
  Manages the torrent processing queue.
  """

  use GenServer

  alias ProcessingQueue.{Torrent, Processor}

  require Logger

  @type state :: %{
          torrents: %{String.t() => Torrent.t()}
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec add_magnet(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_magnet(magnet, opts \\ []) do
    GenServer.call(__MODULE__, {:add_magnet, magnet, opts})
  end

  @spec add_torrent_file(binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_torrent_file(torrent_data, opts \\ []) when is_binary(torrent_data) do
    GenServer.call(__MODULE__, {:add_torrent_file, torrent_data, opts})
  end

  @spec get_torrent(String.t()) :: {:ok, Torrent.t()} | {:error, :not_found}
  def get_torrent(hash) do
    GenServer.call(__MODULE__, {:get_torrent, String.downcase(hash)})
  end

  @spec list_torrents() :: [Torrent.t()]
  def list_torrents do
    GenServer.call(__MODULE__, :list_torrents)
  end

  @spec remove_torrent(String.t()) :: :ok | {:error, term()}
  def remove_torrent(hash) do
    GenServer.call(__MODULE__, {:remove_torrent, String.downcase(hash)})
  end

  @spec pause_torrent(String.t()) :: :ok | {:error, term()}
  def pause_torrent(hash) do
    GenServer.call(__MODULE__, {:pause_torrent, String.downcase(hash)})
  end

  @spec resume_torrent(String.t()) :: :ok | {:error, term()}
  def resume_torrent(hash) do
    GenServer.call(__MODULE__, {:resume_torrent, String.downcase(hash)})
  end

  @spec update_torrent(Torrent.t()) :: :ok
  def update_torrent(torrent) do
    GenServer.cast(__MODULE__, {:update_torrent, torrent})
  end

  @spec cleanup_torrents([String.t()]) :: :ok
  def cleanup_torrents(hashes) do
    GenServer.cast(__MODULE__, {:cleanup_torrents, hashes})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{torrents: %{}}}
  end

  @impl true
  def handle_call({:add_magnet, magnet, opts}, _from, state) do
    case extract_hash(magnet) do
      {:ok, hash} ->
        hash = String.downcase(hash)

        case Map.get(state.torrents, hash) do
          nil ->
            # Torrent doesn't exist, add it
            add_new_torrent(magnet, hash, opts, state)

          %Torrent{state: torrent_state} when torrent_state in [:success, :failed] ->
            # Torrent exists but is in terminal state, remove and re-add
            Logger.info(
              "Torrent #{hash} already exists in #{torrent_state} state, removing and re-adding"
            )

            stop_processor(hash)
            unregister_gid(hash)

            # Remove old torrent from state
            new_state = %{state | torrents: Map.delete(state.torrents, hash)}

            # Add new torrent
            add_new_torrent(magnet, hash, opts, new_state)

          %Torrent{state: torrent_state} ->
            # Torrent exists and is still processing
            Logger.warning(
              "Torrent #{hash} already exists in #{torrent_state} state, rejecting duplicate"
            )

            {:reply, {:error, :already_exists}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp add_new_torrent(magnet, hash, opts, state) do
    torrent = Torrent.new(hash, magnet)
    torrent = apply_opts(torrent, opts)

    Logger.debug("Adding torrent #{hash} to Real Debrid")
    client = get_rd_client()

    case RealDebrid.Api.AddMagnet.add(client, magnet) do
      {:ok, response} ->
        rd_id = response.id
        torrent = %{torrent | rd_id: rd_id}
        torrent = Torrent.transition(torrent, :waiting_metadata)

        start_processor(torrent)

        new_state = put_in(state.torrents[hash], torrent)
        Logger.info("Added torrent #{hash} to processing queue with RD ID #{rd_id}")
        {:reply, {:ok, hash}, new_state}

      {:error, reason} ->
        Logger.error("Failed to add torrent #{hash} to Real Debrid: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_torrent_file, torrent_data, opts}, _from, state) do
    case ProcessingQueue.TorrentParser.extract_infohash(torrent_data) do
      {:ok, hash} ->
        hash = String.downcase(hash)

        case Map.get(state.torrents, hash) do
          nil ->
            # Torrent doesn't exist, add it
            add_new_torrent_file(torrent_data, hash, opts, state)

          %Torrent{state: torrent_state} when torrent_state in [:success, :failed] ->
            # Torrent exists but is in terminal state, remove and re-add
            Logger.info(
              "Torrent file #{hash} already exists in #{torrent_state} state, removing and re-adding"
            )

            stop_processor(hash)
            unregister_gid(hash)

            # Remove old torrent from state
            new_state = %{state | torrents: Map.delete(state.torrents, hash)}

            # Add new torrent
            add_new_torrent_file(torrent_data, hash, opts, new_state)

          %Torrent{state: torrent_state} ->
            # Torrent exists and is still processing
            Logger.warning(
              "Torrent file #{hash} already exists in #{torrent_state} state, rejecting duplicate"
            )

            {:reply, {:error, :already_exists}, state}
        end

      {:error, reason} ->
        Logger.error("Failed to extract infohash from torrent file: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  defp add_new_torrent_file(torrent_data, hash, opts, state) do
    magnet = "magnet:?xt=urn:btih:#{hash}"
    torrent = Torrent.new(hash, magnet)
    torrent = apply_opts(torrent, opts)

    Logger.debug("Adding torrent file #{hash} to Real Debrid")
    client = get_rd_client()

    case RealDebrid.Api.AddTorrent.add(client, torrent_data) do
      {:ok, response} ->
        rd_id = response.id
        torrent = %{torrent | rd_id: rd_id}
        torrent = Torrent.transition(torrent, :waiting_metadata)

        start_processor(torrent)

        new_state = put_in(state.torrents[hash], torrent)
        Logger.info("Added torrent file #{hash} to processing queue with RD ID #{rd_id}")
        {:reply, {:ok, hash}, new_state}

      {:error, reason} ->
        Logger.error("Failed to add torrent file #{hash} to Real Debrid: #{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_torrent, hash}, _from, state) do
    case Map.get(state.torrents, hash) do
      nil -> {:reply, {:error, :not_found}, state}
      torrent -> {:reply, {:ok, torrent}, state}
    end
  end

  @impl true
  def handle_call(:list_torrents, _from, state) do
    torrents = Map.values(state.torrents)
    {:reply, torrents, state}
  end

  @impl true
  def handle_call({:remove_torrent, hash}, _from, state) do
    stop_processor(hash)

    case Map.get(state.torrents, hash) do
      %Torrent{rd_id: rd_id, state: torrent_state} when not is_nil(rd_id) ->
        if torrent_state == :failed do
          Logger.debug("Removing failed torrent #{hash} - cleaning up Real-Debrid")
          cleanup_real_debrid(rd_id, hash)
        else
          Logger.debug(
            "Removing #{torrent_state} torrent #{hash} - keeping Real-Debrid resources (Sonarr-initiated removal)"
          )
        end

      _ ->
        Logger.debug("Removing torrent #{hash} - no Real-Debrid ID")
    end

    unregister_gid(hash)

    new_state = %{state | torrents: Map.delete(state.torrents, hash)}
    Logger.info("Removed torrent #{hash} from queue")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:pause_torrent, hash}, _from, state) do
    case Map.get(state.torrents, hash) do
      nil ->
        {:reply, {:error, :not_found}, state}

      torrent ->
        stop_processor(hash)
        updated = Torrent.set_error(torrent, "Paused by user")
        new_state = put_in(state.torrents[hash], updated)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:resume_torrent, hash}, _from, state) do
    case Map.get(state.torrents, hash) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %Torrent{state: :failed} = torrent ->
        updated = %{torrent | state: :pending, error: nil, failed_at: nil}
        start_processor(updated)
        new_state = put_in(state.torrents[hash], updated)
        {:reply, :ok, new_state}

      _ ->
        {:reply, {:error, :not_failed}, state}
    end
  end

  @impl true
  def handle_cast({:update_torrent, torrent}, state) do
    new_state = put_in(state.torrents[torrent.hash], torrent)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:cleanup_torrents, hashes}, state) do
    Logger.debug("Cleanup torrents called for #{length(hashes)} hashes")

    Enum.each(hashes, fn hash ->
      case Map.get(state.torrents, hash) do
        %Torrent{rd_id: rd_id, state: :failed} when not is_nil(rd_id) ->
          Logger.debug("Cleanup: #{hash} is failed - cleaning up Real-Debrid ID #{rd_id}")
          cleanup_real_debrid(rd_id, hash)

        %Torrent{state: torrent_state} ->
          Logger.warning(
            "Cleanup called for non-failed torrent #{hash} in state #{torrent_state} - skipping RD cleanup"
          )

        nil ->
          Logger.debug("Cleanup: #{hash} not found in state - already removed")
      end

      unregister_gid(hash)
    end)

    new_torrents =
      Enum.reduce(hashes, state.torrents, fn hash, acc ->
        Map.delete(acc, hash)
      end)

    Logger.debug("Cleanup complete: removed #{length(hashes)} torrents from state")
    {:noreply, %{state | torrents: new_torrents}}
  end

  # Private functions

  defp extract_hash(magnet) do
    case Regex.run(~r/btih:([a-fA-F0-9]{40})/i, magnet) do
      [_, hash] ->
        {:ok, String.upcase(hash)}

      nil ->
        case Regex.run(~r/btih:([a-zA-Z2-7]{32})/i, magnet) do
          [_, base32_hash] ->
            case Base.decode32(String.upcase(base32_hash)) do
              {:ok, binary} -> {:ok, Base.encode16(binary, case: :upper)}
              :error -> {:error, :invalid_magnet}
            end

          nil ->
            {:error, :invalid_magnet}
        end
    end
  end

  defp apply_opts(torrent, opts) do
    torrent
    |> maybe_set(:expected_files, Keyword.get(opts, :expected_files))
    |> maybe_set(:servarr_url, Keyword.get(opts, :servarr_url))
    |> maybe_set(:servarr_api_key, Keyword.get(opts, :servarr_api_key))
  end

  defp maybe_set(torrent, _key, nil), do: torrent
  defp maybe_set(torrent, key, value), do: Map.put(torrent, key, value)

  defp start_processor(torrent) do
    DynamicSupervisor.start_child(
      ProcessingQueue.TorrentSupervisor,
      {Processor, torrent}
    )
  end

  defp stop_processor(hash) do
    case Registry.lookup(ProcessingQueue.TorrentRegistry, hash) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(ProcessingQueue.TorrentSupervisor, pid)

      [] ->
        :ok
    end
  end

  defp cleanup_real_debrid(rd_id, hash) do
    Task.start(fn ->
      try do
        client = get_rd_client()

        case RealDebrid.Api.Delete.delete(client, rd_id) do
          :ok ->
            Logger.info("Deleted torrent #{hash} (RD ID: #{rd_id}) from Real-Debrid")

          {:error, reason} ->
            Logger.warning(
              "Failed to delete torrent #{hash} (RD ID: #{rd_id}) from Real-Debrid: #{inspect(reason)}"
            )
        end
      rescue
        e ->
          Logger.error(
            "Error deleting torrent #{hash} (RD ID: #{rd_id}) from Real-Debrid: #{inspect(e)}"
          )
      end
    end)
  end

  defp get_rd_client do
    token = Aria2Debrid.Config.real_debrid_token()
    max_requests = Aria2Debrid.Config.requests_per_minute()
    max_retries = Aria2Debrid.Config.max_retries()

    RealDebrid.Client.new(token,
      max_requests_per_minute: max_requests,
      max_retries: max_retries
    )
  end

  defp unregister_gid(hash) do
    # Try to call GidRegistry.unregister if the module is available
    # Use dynamic module reference to avoid compile-time circular dependency warning
    gid_registry_mod = :"Aria2Api.GidRegistry"

    if Code.ensure_loaded?(gid_registry_mod) do
      try do
        apply(gid_registry_mod, :unregister, [hash])
      rescue
        e in UndefinedFunctionError ->
          Logger.debug("GidRegistry.unregister failed: #{inspect(e)}, skipping for #{hash}")
          :ok
      end
    else
      Logger.debug("GidRegistry not available, skipping unregister for #{hash}")
      :ok
    end
  end
end

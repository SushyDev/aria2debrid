defmodule Aria2Api.GidRegistry do
  @moduledoc """
  Registry for mapping aria2 GIDs to torrent infohashes.

  aria2 uses 16-character hex GIDs to identify downloads. We generate GIDs
  from the first 16 characters of the torrent infohash (which is 40 chars).

  The registry maintains bidirectional mappings:
  - GID -> Hash (for aria2 API lookups)
  - Hash -> GID (for ProcessingQueue integration)
  """

  use GenServer

  @table_name :aria2_gid_registry

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Generates and registers a GID for a torrent hash.
  """
  @spec register(String.t()) :: String.t()
  def register(hash) do
    GenServer.call(__MODULE__, {:register, hash})
  end

  @doc """
  Looks up the torrent hash for a GID.
  """
  @spec lookup_hash(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def lookup_hash(gid) do
    case :ets.lookup(@table_name, {:gid, String.downcase(gid)}) do
      [{_, hash}] -> {:ok, hash}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Looks up the GID for a torrent hash.
  """
  @spec lookup_gid(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def lookup_gid(hash) do
    case :ets.lookup(@table_name, {:hash, String.downcase(hash)}) do
      [{_, gid}] -> {:ok, gid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Unregisters a GID/hash mapping.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(gid_or_hash) do
    GenServer.call(__MODULE__, {:unregister, gid_or_hash})
  end

  @doc """
  Converts a torrent hash to an aria2 GID.
  aria2 GIDs are 16-character hex strings.
  """
  @spec hash_to_gid(String.t()) :: String.t()
  def hash_to_gid(hash) do
    hash
    |> String.downcase()
    |> String.slice(0, 16)
  end

  @impl true
  def init(_) do
    table = :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, hash}, _from, state) do
    hash = String.downcase(hash)
    gid = hash_to_gid(hash)

    :ets.insert(@table_name, {{:gid, gid}, hash})
    :ets.insert(@table_name, {{:hash, hash}, gid})

    {:reply, gid, state}
  end

  @impl true
  def handle_call({:unregister, key}, _from, state) do
    key = String.downcase(key)

    case :ets.lookup(@table_name, {:gid, key}) do
      [{_, hash}] ->
        gid = key
        :ets.delete(@table_name, {:gid, gid})
        :ets.delete(@table_name, {:hash, hash})

      [] ->
        case :ets.lookup(@table_name, {:hash, key}) do
          [{_, gid}] ->
            hash = key
            :ets.delete(@table_name, {:gid, gid})
            :ets.delete(@table_name, {:hash, hash})

          [] ->
            :ok
        end
    end

    {:reply, :ok, state}
  end
end

defmodule Aria2Api.CredentialCache do
  @moduledoc """
  In-memory cache for validated Servarr credentials.

  Caches successful credential validations for the lifetime of the application
  to avoid repeatedly calling the Servarr API during health checks.

  This is a "verify once" approach - once credentials are validated successfully,
  they remain cached until the application restarts.
  """

  use GenServer
  require Logger

  @type credentials :: {url :: String.t(), api_key :: String.t()}

  ## Client API

  @doc """
  Starts the credential cache.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if credentials have been validated successfully.

  Returns `true` if credentials were previously validated, `false` otherwise.
  """
  @spec validated?(credentials()) :: boolean()
  def validated?({url, api_key}) do
    GenServer.call(__MODULE__, {:validated?, cache_key(url, api_key)})
  end

  @doc """
  Marks credentials as validated.

  Once credentials are marked as validated, they remain cached for the
  lifetime of the application.
  """
  @spec mark_validated(credentials()) :: :ok
  def mark_validated({url, api_key}) do
    GenServer.cast(__MODULE__, {:mark_validated, cache_key(url, api_key)})
  end

  @doc """
  Gets cache statistics (for debugging).

  Returns a map with:
  - `:size` - number of cached credentials
  - `:entries` - list of cached credential keys (hashed for security)
  """
  @spec stats() :: %{size: non_neg_integer(), entries: [String.t()]}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting credential cache")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:validated?, key}, _from, state) do
    {:reply, Map.has_key?(state, key), state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      size: map_size(state),
      entries: Map.keys(state)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:mark_validated, key}, state) do
    {:noreply, Map.put(state, key, true)}
  end

  ## Private Functions

  # Generate a cache key from URL and API key
  # Uses SHA256 hash for security (don't store raw API keys in logs/memory dumps)
  defp cache_key(url, api_key) do
    normalized_url = String.downcase(String.trim_trailing(url, "/"))

    :crypto.hash(:sha256, "#{normalized_url}:#{api_key}")
    |> Base.encode16(case: :lower)
  end
end

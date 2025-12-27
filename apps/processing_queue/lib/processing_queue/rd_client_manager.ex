defmodule ProcessingQueue.RDClientManager do
  @moduledoc """
  Manages a single shared RealDebrid client to avoid resource leaks.

  Each RealDebrid client spawns its own rate limiter GenServer. Creating
  many short-lived clients without cleanup causes a resource leak. This
  module provides a single shared client that is reused across the application.

  ## Resource Management

  The Real-Debrid rate limiter is per-token, so sharing a single client
  across the application is the recommended approach per real_debrid_ex docs.

  If the token configuration changes, the old client is stopped and a new
  one is created.

  ## Usage

      client = RDClientManager.get_client()
      RealDebrid.Api.TorrentInfo.get(client, rd_id)
  """

  use GenServer
  require Logger

  @name __MODULE__

  # Client API

  @doc """
  Starts the RDClientManager GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  Gets the current RealDebrid client.

  Returns `nil` if no token is configured.
  Creates a new client if the token has changed.
  """
  @spec get_client() :: RealDebrid.Client.t() | nil
  def get_client do
    GenServer.call(@name, :get_client, 10_000)
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    {:ok, %{client: nil, token: nil}}
  end

  @impl true
  def handle_call(:get_client, _from, state) do
    current_token = Aria2Debrid.Config.real_debrid_token()

    cond do
      # No token configured
      current_token == nil ->
        {:reply, nil, state}

      # Token unchanged, reuse existing client
      current_token == state.token && state.client != nil ->
        {:reply, state.client, state}

      # Token changed or no client yet
      true ->
        # Stop old client if it exists
        if state.client != nil do
          Logger.info("Real-Debrid token changed, stopping old client")
          RealDebrid.Client.stop(state.client)
        end

        # Create new client
        max_requests = Aria2Debrid.Config.requests_per_minute()
        max_retries = Aria2Debrid.Config.max_retries()

        client =
          RealDebrid.Client.new(current_token,
            max_requests_per_minute: max_requests,
            max_retries: max_retries
          )

        Logger.info("Created new Real-Debrid client")
        {:reply, client, %{client: client, token: current_token}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.client != nil do
      Logger.info("Stopping Real-Debrid client on shutdown")
      RealDebrid.Client.stop(state.client)
    end

    :ok
  end
end

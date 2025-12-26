defmodule ProcessingQueue.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ProcessingQueue.TorrentRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ProcessingQueue.TorrentSupervisor},
      ProcessingQueue.RDClientManager,
      ProcessingQueue.Manager,
      ProcessingQueue.Cleanup
    ]

    opts = [strategy: :one_for_one, name: ProcessingQueue.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

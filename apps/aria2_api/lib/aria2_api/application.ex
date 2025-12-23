defmodule Aria2Api.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Aria2Debrid.Config.aria2_port()
    host = Aria2Debrid.Config.aria2_host()

    children = [
      {Aria2Api.GidRegistry, []},
      {Bandit, plug: Aria2Api.Router, port: port, ip: parse_host(host)}
    ]

    opts = [strategy: :one_for_one, name: Aria2Api.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_host(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp parse_host(_), do: {0, 0, 0, 0}
end

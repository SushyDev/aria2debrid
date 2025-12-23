defmodule Aria2Api.Router do
  @moduledoc """
  Main Plug router for aria2 XML-RPC API emulation.

  This implements the aria2 XML-RPC protocol used by Sonarr/Radarr for download client integration.
  Note: Sonarr/Radarr only use XML-RPC, not JSON-RPC.

  ## Endpoints

  - POST /rpc - Main XML-RPC endpoint (Sonarr/Radarr default)
  - GET /health - Health check endpoint

  ## XML-RPC Format

  Request:
  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <methodCall>
    <methodName>aria2.getVersion</methodName>
    <params>
      <param><value><string>token:secret</string></value></param>
    </params>
  </methodCall>
  ```

  Response:
  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <methodResponse>
    <params>
      <param>
        <value>
          <struct>
            <member><name>version</name><value><string>1.37.0</string></value></member>
          </struct>
        </value>
      </param>
    </params>
  </methodResponse>
  ```
  """

  use Plug.Router
  require Logger

  alias Aria2Api.Handlers.{Downloads, System}
  alias Aria2Api.XmlRpc

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:read_body_early)
  plug(:dispatch)

  defp read_body_early(conn, _opts) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        assign(conn, :raw_body, "")

      {:error, _reason} ->
        assign(conn, :raw_body, "")
    end
  end

  match "/health" do
    result = %{
      status: "healthy",
      version: "1.37.0",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case conn.method do
      "HEAD" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, "")

      "GET" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(result))

      _ ->
        send_resp(conn, 405, "Method not allowed")
    end
  end

  post "/rpc" do
    handle_xmlrpc_request(conn)
  end

  defp handle_xmlrpc_request(conn) do
    body = conn.assigns[:raw_body] || ""

    case XmlRpc.parse_request(body) do
      {:ok, method, params} ->
        {secret, params} = extract_secret(params)

        case validate_secret(secret) do
          :ok ->
            result = dispatch_method(method, params)
            send_xmlrpc_response(conn, result)

          {:error, message} ->
            send_xmlrpc_fault(conn, -32600, message)
        end

      {:error, reason} ->
        Logger.warning("XML-RPC parse error: #{reason}")
        send_xmlrpc_fault(conn, -32700, "Parse error: #{reason}")
    end
  end

  defp send_xmlrpc_response(conn, {:ok, result}) do
    response = XmlRpc.encode_response(result)

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, response)
  end

  defp send_xmlrpc_response(conn, {:error, code, message}) do
    send_xmlrpc_fault(conn, code, message)
  end

  defp send_xmlrpc_fault(conn, code, message) do
    response = XmlRpc.encode_fault(code, message)

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, response)
  end

  defp extract_secret([<<"token:", _rest::binary>> = token | rest]) do
    secret = String.replace_prefix(token, "token:", "")
    {secret, rest}
  end

  defp extract_secret(params), do: {nil, params}

  defp validate_secret(provided_secret) do
    case Aria2Debrid.Config.aria2_secret() do
      nil -> :ok
      "" -> :ok
      expected when provided_secret == expected -> :ok
      _expected -> {:error, "Unauthorized"}
    end
  end

  defp dispatch_method("aria2.addUri", params), do: Downloads.add_uri(params)
  defp dispatch_method("aria2.addTorrent", params), do: Downloads.add_torrent(params)
  defp dispatch_method("aria2.tellStatus", params), do: Downloads.tell_status(params)
  defp dispatch_method("aria2.tellActive", params), do: Downloads.tell_active(params)
  defp dispatch_method("aria2.tellWaiting", params), do: Downloads.tell_waiting(params)
  defp dispatch_method("aria2.tellStopped", params), do: Downloads.tell_stopped(params)
  defp dispatch_method("aria2.remove", params), do: Downloads.remove(params)
  defp dispatch_method("aria2.forceRemove", params), do: Downloads.force_remove(params)

  defp dispatch_method("aria2.removeDownloadResult", params),
    do: Downloads.remove_download_result(params)

  defp dispatch_method("aria2.pause", params), do: Downloads.pause(params)
  defp dispatch_method("aria2.unpause", params), do: Downloads.unpause(params)
  defp dispatch_method("aria2.getGlobalOption", _params), do: System.get_global_option()
  defp dispatch_method("aria2.getGlobalStat", _params), do: System.get_global_stat()
  defp dispatch_method("aria2.getVersion", _params), do: System.get_version()
  defp dispatch_method("aria2.getSessionInfo", _params), do: System.get_session_info()

  defp dispatch_method("system.multicall", params), do: handle_multicall(params)
  defp dispatch_method("system.listMethods", _params), do: System.list_methods()

  defp dispatch_method(method, _params) do
    Logger.warning("Unknown aria2 method: #{method}")
    {:error, -32601, "Method not found: #{method}"}
  end

  defp handle_multicall([calls]) when is_list(calls) do
    results =
      Enum.map(calls, fn
        %{"methodName" => method, "params" => params} ->
          case dispatch_method(method, params) do
            {:ok, result} -> [result]
            {:error, code, message} -> %{"faultCode" => code, "faultString" => message}
          end

        _ ->
          %{"faultCode" => -32600, "faultString" => "Invalid multicall format"}
      end)

    {:ok, results}
  end

  defp handle_multicall(_), do: {:error, -32602, "Invalid params"}

  match _ do
    Logger.warning("Unmatched route: #{conn.method} #{conn.request_path}")
    send_resp(conn, 404, "Not Found")
  end
end

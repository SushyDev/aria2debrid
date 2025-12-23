defmodule Aria2Api.SonarrCompatibilityTest do
  @moduledoc """
  Tests that verify compatibility with Sonarr/Radarr's aria2 implementation.

  These tests mimic the exact XML-RPC requests that Sonarr sends to aria2,
  based on the source code in:
  - src/NzbDrone.Core/Download/Clients/Aria2/Aria2Proxy.cs
  - src/NzbDrone.Common/Http/XmlRpcRequestBuilder.cs
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Aria2Api.Router

  @opts Router.init([])

  describe "Sonarr connection test - aria2.getVersion" do
    @doc """
    Sonarr's TestConnection() calls aria2.getVersion to verify the connection.
    See: Aria2.cs:235-262 and Aria2Proxy.cs:32-41

    The request format is XML-RPC with content-type text/xml.
    """
    test "responds to XML-RPC aria2.getVersion exactly like Sonarr expects" do
      # This is exactly the XML that Sonarr's XmlRpcRequestBuilder generates
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.getVersion</methodName>
        <params>
          <param><value><string>token:MySecretToken</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/xml; charset=utf-8"]

      # Parse the response XML
      response_body = conn.resp_body

      # Verify it's valid XML and contains the version
      assert response_body =~ ~r/<methodResponse>/
      assert response_body =~ ~r/<params>/
      assert response_body =~ ~r/<param>/
      assert response_body =~ ~r/<value>/
      assert response_body =~ ~r/<struct>/

      # Check for version member
      assert response_body =~ ~r/<name>version<\/name>/
      assert response_body =~ ~r/<string>1\.37\.0<\/string>/
    end

    test "version is >= 1.34.0 (Sonarr's minimum required version)" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.getVersion</methodName>
        <params>
          <param><value><string>token:</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200

      # Extract version from response
      {:ok, version_match} =
        Regex.run(~r/<name>version<\/name>\s*<value>\s*<string>([^<]+)<\/string>/, conn.resp_body,
          capture: :all_but_first
        )
        |> then(fn
          [version] -> {:ok, version}
          _ -> {:error, :not_found}
        end)

      # Sonarr requires version >= 1.34.0
      assert Version.compare(version_match, "1.34.0") in [:gt, :eq]
    end
  end

  describe "Sonarr GetTorrents - aria2.tellActive/tellWaiting/tellStopped" do
    @doc """
    Sonarr calls these methods to list downloads.
    See: Aria2Proxy.cs:71-86
    """
    test "aria2.tellActive returns array of download statuses" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.tellActive</methodName>
        <params>
          <param><value><string>token:</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      # Should return an array (even if empty)
      assert conn.resp_body =~ ~r/<array>/
      assert conn.resp_body =~ ~r/<data>/
    end

    test "aria2.tellWaiting with offset and num parameters" do
      # Sonarr calls: aria2.tellWaiting(token, 0, 10240)
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.tellWaiting</methodName>
        <params>
          <param><value><string>token:</string></value></param>
          <param><value><int>0</int></value></param>
          <param><value><int>10240</int></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      assert conn.resp_body =~ ~r/<array>/
    end

    test "aria2.tellStopped with offset and num parameters" do
      # Sonarr calls: aria2.tellStopped(token, 0, 10240)
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.tellStopped</methodName>
        <params>
          <param><value><string>token:</string></value></param>
          <param><value><int>0</int></value></param>
          <param><value><int>10240</int></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      assert conn.resp_body =~ ~r/<array>/
    end
  end

  describe "Sonarr AddMagnet - aria2.addUri" do
    @doc """
    Sonarr's AddMagnet calls aria2.addUri with the magnet link and directory option.
    See: Aria2Proxy.cs:99-112
    """
    test "aria2.addUri with magnet link and dir option" do
      # This is the format Sonarr uses
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.addUri</methodName>
        <params>
          <param><value><string>token:</string></value></param>
          <param>
            <value>
              <array>
                <data>
                  <value><string>magnet:?xt=urn:btih:abc123def456&amp;dn=Test+Torrent</string></value>
                </data>
              </array>
            </value>
          </param>
          <param>
            <value>
              <struct>
                <member>
                  <name>dir</name>
                  <value>/downloads</value>
                </member>
              </struct>
            </value>
          </param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      # Should return a GID (16 character hex string)
      # Response should contain either a result with the GID or a fault
      assert conn.resp_body =~ ~r/<methodResponse>/
    end
  end

  describe "Sonarr RemoveTorrent - aria2.forceRemove" do
    @doc """
    Sonarr calls aria2.forceRemove to remove a download.
    See: Aria2Proxy.cs:131-138
    """
    test "aria2.forceRemove with GID" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.forceRemove</methodName>
        <params>
          <param><value><string>token:</string></value></param>
          <param><value><string>0123456789abcdef</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      # Should return an error since the GID doesn't exist, or success if it does
    end
  end

  describe "Sonarr RemoveCompletedTorrent - aria2.removeDownloadResult" do
    @doc """
    Sonarr calls aria2.removeDownloadResult to clean up completed downloads.
    See: Aria2Proxy.cs:140-147
    """
    test "aria2.removeDownloadResult with GID" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.removeDownloadResult</methodName>
        <params>
          <param><value><string>token:</string></value></param>
          <param><value><string>0123456789abcdef</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      # Should return "OK" even if GID doesn't exist
      assert conn.resp_body =~ ~r/<string>OK<\/string>/
    end
  end

  describe "Sonarr GetGlobals - aria2.getGlobalOption" do
    @doc """
    Sonarr calls aria2.getGlobalOption to get download directory.
    See: Aria2Proxy.cs:88-97
    """
    test "aria2.getGlobalOption returns directory info" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.getGlobalOption</methodName>
        <params>
          <param><value><string>token:</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      assert conn.resp_body =~ ~r/<struct>/
      # Should return a struct with 'dir' member
      assert conn.resp_body =~ ~r/<name>dir<\/name>/
    end
  end

  describe "Sonarr GetFromGID - aria2.tellStatus" do
    @doc """
    Sonarr calls aria2.tellStatus to get status of a specific download.
    See: Aria2Proxy.cs:43-50
    """
    test "aria2.tellStatus with non-existent GID returns error" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.tellStatus</methodName>
        <params>
          <param><value><string>token:</string></value></param>
          <param><value><string>nonexistent12345</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      # Should return a fault since GID doesn't exist
      assert conn.resp_body =~ ~r/<fault>/
    end
  end

  describe "XML-RPC fault handling" do
    test "invalid method returns proper XML-RPC fault" do
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.nonExistentMethod</methodName>
        <params>
          <param><value><string>token:</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
      assert conn.resp_body =~ ~r/<fault>/
      assert conn.resp_body =~ ~r/<name>faultCode<\/name>/
      assert conn.resp_body =~ ~r/<name>faultString<\/name>/
    end

    test "malformed XML returns parse error fault" do
      conn =
        conn(:post, "/rpc", "this is not valid xml")
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<fault>/
    end
  end

  describe "endpoint path compatibility" do
    test "POST /rpc is the default endpoint (Sonarr default RpcPath)" do
      # Sonarr defaults to /rpc path
      # See: Aria2Settings.cs:23
      xml_request = """
      <?xml version="1.0" encoding="utf-8"?>
      <methodCall>
        <methodName>aria2.getVersion</methodName>
        <params>
          <param><value><string>token:</string></value></param>
        </params>
      </methodCall>
      """

      conn =
        conn(:post, "/rpc", String.trim(xml_request))
        |> put_req_header("content-type", "text/xml")
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~r/<methodResponse>/
    end
  end
end

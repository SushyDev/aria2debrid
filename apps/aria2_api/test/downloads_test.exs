defmodule Aria2Api.Handlers.DownloadsTest do
  use ExUnit.Case, async: true

  alias Aria2Api.Handlers.Downloads

  describe "parse_servarr_credentials/1" do
    test "parses valid credentials from dir option" do
      options = %{"dir" => "http://sonarr:8989|my-api-key-123"}

      assert {url, api_key} = Downloads.parse_servarr_credentials(options)
      assert url == "http://sonarr:8989"
      assert api_key == "my-api-key-123"
    end

    test "parses https URL" do
      options = %{"dir" => "https://radarr.example.com:7878|secret-key"}

      assert {url, api_key} = Downloads.parse_servarr_credentials(options)
      assert url == "https://radarr.example.com:7878"
      assert api_key == "secret-key"
    end

    test "parses URL with path" do
      options = %{"dir" => "http://localhost:8989/sonarr|api-key"}

      assert {url, api_key} = Downloads.parse_servarr_credentials(options)
      assert url == "http://localhost:8989/sonarr"
      assert api_key == "api-key"
    end

    test "returns nil for regular directory path" do
      options = %{"dir" => "/downloads/movies"}

      assert {nil, nil} = Downloads.parse_servarr_credentials(options)
    end

    test "returns nil for empty dir" do
      options = %{"dir" => ""}

      assert {nil, nil} = Downloads.parse_servarr_credentials(options)
    end

    test "returns nil for missing dir option" do
      options = %{}

      assert {nil, nil} = Downloads.parse_servarr_credentials(options)
    end

    test "returns nil for nil options" do
      assert {nil, nil} = Downloads.parse_servarr_credentials(nil)
    end

    test "returns nil for non-http URL in dir" do
      options = %{"dir" => "ftp://server.com|key"}

      assert {nil, nil} = Downloads.parse_servarr_credentials(options)
    end

    test "handles URL with multiple colons (ipv6)" do
      # IPv6 addresses have many colons, the pipe delimiter handles this
      options = %{"dir" => "http://[::1]:8989|api-key"}

      assert {url, api_key} = Downloads.parse_servarr_credentials(options)
      assert url == "http://[::1]:8989"
      assert api_key == "api-key"
    end

    test "handles api key with special characters" do
      options = %{"dir" => "http://sonarr:8989|abc123!@#$%"}

      assert {url, api_key} = Downloads.parse_servarr_credentials(options)
      assert url == "http://sonarr:8989"
      assert api_key == "abc123!@#$%"
    end
  end
end

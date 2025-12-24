defmodule Aria2Api.Handlers.DownloadsTest do
  use ExUnit.Case, async: true

  alias Aria2Api.Handlers.Downloads

  describe "filter_by_servarr/2" do
    setup do
      # Create sample torrents
      torrent1 = %ProcessingQueue.Torrent{
        hash: "ABC123DEF456789012345678901234567890ABCD",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :waiting_download,
        servarr_url: "http://sonarr:8989",
        servarr_api_key: "sonarr-key-123",
        added_at: DateTime.utc_now()
      }

      torrent2 = %ProcessingQueue.Torrent{
        hash: "DEF456ABC789012345678901234567890ABCDEF12",
        magnet: "magnet:?xt=urn:btih:def456",
        state: :success,
        servarr_url: "http://radarr:7878",
        servarr_api_key: "radarr-key-456",
        added_at: DateTime.utc_now()
      }

      torrent3 = %ProcessingQueue.Torrent{
        hash: "GHI789012345678901234567890ABCDEF12345678",
        magnet: "magnet:?xt=urn:btih:ghi789",
        state: :waiting_download,
        servarr_url: "http://sonarr:8989",
        servarr_api_key: "sonarr-key-123",
        added_at: DateTime.utc_now()
      }

      torrent4 = %ProcessingQueue.Torrent{
        hash: "JKL012345678901234567890ABCDEF1234567890",
        magnet: "magnet:?xt=urn:btih:jkl012",
        state: :failed,
        servarr_url: nil,
        servarr_api_key: nil,
        added_at: DateTime.utc_now()
      }

      {:ok, torrents: [torrent1, torrent2, torrent3, torrent4]}
    end

    test "returns empty list when no credentials provided", %{
      torrents: torrents
    } do
      result = Downloads.filter_by_servarr(torrents, nil)
      assert length(result) == 0
    end
  end
end

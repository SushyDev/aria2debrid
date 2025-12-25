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

  describe "torrent_to_aria2/2" do
    test "always includes at least one file entry even with nil files" do
      torrent = %ProcessingQueue.Torrent{
        hash: "abc123def456",
        name: "Test Torrent",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :waiting_metadata,
        files: nil,
        size: 1024,
        save_path: "/downloads",
        added_at: DateTime.utc_now()
      }

      result = Downloads.torrent_to_aria2(torrent, "0000000000000001")

      assert is_list(result["files"])
      assert length(result["files"]) >= 1

      # Verify the placeholder file has required fields
      first_file = hd(result["files"])
      assert first_file["path"] == "/downloads/Test Torrent"
      assert first_file["length"] == "1024"
      assert first_file["selected"] == "true"
    end

    test "always includes at least one file entry even with empty files array" do
      torrent = %ProcessingQueue.Torrent{
        hash: "abc123def456",
        name: nil,
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :selecting_files,
        files: [],
        size: 2048,
        save_path: "/downloads",
        added_at: DateTime.utc_now()
      }

      result = Downloads.torrent_to_aria2(torrent, "0000000000000002")

      assert is_list(result["files"])
      assert length(result["files"]) >= 1

      # When name is nil, should use hash as filename
      first_file = hd(result["files"])
      assert first_file["path"] == "/downloads/abc123def456"
      assert first_file["length"] == "2048"
    end

    test "always includes at least one file entry when no files are selected" do
      torrent = %ProcessingQueue.Torrent{
        hash: "abc123def456",
        name: "Multi-File Torrent",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :selecting_files,
        files: [
          %{"path" => "file1.mkv", "bytes" => 1000, "selected" => 0},
          %{"path" => "file2.mkv", "bytes" => 2000, "selected" => 0}
        ],
        size: 3000,
        save_path: "/downloads",
        added_at: DateTime.utc_now()
      }

      result = Downloads.torrent_to_aria2(torrent, "0000000000000003")

      # Should return placeholder since no files are selected
      assert is_list(result["files"])
      assert length(result["files"]) >= 1

      first_file = hd(result["files"])
      assert first_file["path"] == "/downloads/Multi-File Torrent"
    end

    test "returns actual files when files are selected" do
      torrent = %ProcessingQueue.Torrent{
        hash: "abc123def456",
        name: "Multi-File Torrent",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :waiting_download,
        files: [
          %{"path" => "file1.mkv", "bytes" => 1000, "selected" => 1},
          %{"path" => "file2.mkv", "bytes" => 2000, "selected" => 1}
        ],
        size: 3000,
        save_path: "/downloads",
        added_at: DateTime.utc_now()
      }

      result = Downloads.torrent_to_aria2(torrent, "0000000000000004")

      # Should return actual selected files
      assert is_list(result["files"])
      assert length(result["files"]) == 2

      assert Enum.at(result["files"], 0)["path"] == "/downloads/file1.mkv"
      assert Enum.at(result["files"], 1)["path"] == "/downloads/file2.mkv"
    end
  end
end

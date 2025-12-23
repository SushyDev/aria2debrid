defmodule ServarrClient.QueueItemTest do
  use ExUnit.Case, async: true

  alias ServarrClient.QueueItem

  describe "from_api/1" do
    test "parses Sonarr queue item" do
      data = %{
        "id" => 123,
        "downloadId" => "ABC123DEF456",
        "title" => "Some.Show.S01E01.720p",
        "status" => "downloading",
        "trackedDownloadStatus" => "ok",
        "trackedDownloadState" => "downloading",
        "statusMessages" => [],
        "size" => 1_000_000_000,
        "sizeleft" => 500_000_000,
        "seriesId" => 1,
        "episodeId" => 10,
        "seasonNumber" => 1
      }

      item = QueueItem.from_api(data)

      assert item.id == 123
      assert item.download_id == "ABC123DEF456"
      assert item.title == "Some.Show.S01E01.720p"
      assert item.series_id == 1
      assert item.episode_id == 10
    end

    test "parses Radarr queue item" do
      data = %{
        "id" => 456,
        "downloadId" => "XYZ789",
        "title" => "Some.Movie.2024.1080p",
        "status" => "completed",
        "size" => 5_000_000_000,
        "sizeleft" => 0,
        "movieId" => 42
      }

      item = QueueItem.from_api(data)

      assert item.id == 456
      assert item.movie_id == 42
      assert item.series_id == nil
    end
  end

  describe "progress/1" do
    test "calculates progress correctly" do
      item = %QueueItem{size: 1000, sizeleft: 250}
      assert QueueItem.progress(item) == 75.0
    end

    test "returns 0 for zero size" do
      item = %QueueItem{size: 0, sizeleft: 0}
      assert QueueItem.progress(item) == 0.0
    end
  end

  describe "expected_file_count/1" do
    test "returns 1 for movie" do
      item = %QueueItem{movie_id: 1}
      assert QueueItem.expected_file_count(item) == 1
    end

    test "returns 1 for single episode" do
      item = %QueueItem{episode_id: 1}
      assert QueueItem.expected_file_count(item) == 1
    end
  end

  describe "has_warning?/1" do
    test "returns true for warning status" do
      item = %QueueItem{tracked_download_status: "warning"}
      assert QueueItem.has_warning?(item)
    end

    test "returns false for ok status" do
      item = %QueueItem{tracked_download_status: "ok"}
      refute QueueItem.has_warning?(item)
    end
  end
end

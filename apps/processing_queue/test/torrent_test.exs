defmodule ProcessingQueue.TorrentTest do
  use ExUnit.Case, async: true

  alias ProcessingQueue.Torrent

  describe "new/2" do
    test "creates a new torrent" do
      torrent = Torrent.new("abc123", "magnet:?xt=urn:btih:abc123")

      assert torrent.hash == "abc123"
      assert torrent.magnet == "magnet:?xt=urn:btih:abc123"
      assert torrent.state == :pending
      assert torrent.progress == 0.0
    end

    test "downcases hash" do
      torrent = Torrent.new("ABC123", "magnet:?xt=urn:btih:ABC123")
      assert torrent.hash == "abc123"
    end
  end

  describe "transition/2" do
    test "transitions to new state" do
      torrent = Torrent.new("abc", "magnet:...")
      updated = Torrent.transition(torrent, :adding_rd)

      assert updated.state == :adding_rd
    end

    test "sets completed_at on success" do
      torrent = Torrent.new("abc", "magnet:...")
      updated = Torrent.transition(torrent, :success)

      assert updated.state == :success
      assert updated.completed_at != nil
      assert updated.progress == 100.0
    end

    test "sets failed_at on failure" do
      torrent = Torrent.new("abc", "magnet:...")
      updated = Torrent.transition(torrent, :failed)

      assert updated.state == :failed
      assert updated.failed_at != nil
    end
  end

  describe "processing?/1" do
    test "returns true for processing states" do
      for state <- [:pending, :adding_rd, :waiting_metadata, :selecting_files] do
        torrent = %Torrent{hash: "abc", magnet: "...", state: state, added_at: DateTime.utc_now()}
        assert Torrent.processing?(torrent)
      end
    end

    test "returns false for terminal states" do
      for state <- [:success, :failed] do
        torrent = %Torrent{hash: "abc", magnet: "...", state: state, added_at: DateTime.utc_now()}
        refute Torrent.processing?(torrent)
      end
    end
  end
end

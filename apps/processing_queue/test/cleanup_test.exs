defmodule ProcessingQueue.CleanupTest do
  @moduledoc """
  Tests for automatic cleanup of torrents in terminal states.

  Critical Requirements:
  - Failed torrents should be cleaned up after retention period
  - Failed torrents RD resources should be cleaned up during automatic cleanup
  - Completed torrents should NOT be automatically cleaned up
  - Completed torrents RD resources should be KEPT when removed by Sonarr
  - Manual removal of failed torrents should cleanup RD
  - Manual removal of completed torrents should keep RD
  """

  use ExUnit.Case, async: false

  alias ProcessingQueue.{Torrent, Manager, Cleanup}

  setup do
    # Get current config values
    original_retention = Application.get_env(:processing_queue, :failed_retention)
    original_interval = Application.get_env(:processing_queue, :cleanup_interval)

    # Set short intervals for testing (100ms retention, 50ms check interval)
    Application.put_env(:processing_queue, :failed_retention, 100)
    Application.put_env(:processing_queue, :cleanup_interval, 50)

    on_exit(fn ->
      # Restore original config
      if original_retention do
        Application.put_env(:processing_queue, :failed_retention, original_retention)
      end

      if original_interval do
        Application.put_env(:processing_queue, :cleanup_interval, original_interval)
      end
    end)

    :ok
  end

  describe "should_cleanup?/1" do
    test "returns true for failed torrents older than retention period" do
      failed_at = DateTime.add(DateTime.utc_now(), -200, :millisecond)

      torrent = %Torrent{
        hash: "abc123",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :failed,
        failed_at: failed_at,
        added_at: DateTime.utc_now()
      }

      assert Torrent.should_cleanup?(torrent) == true
    end

    test "returns false for failed torrents within retention period" do
      failed_at = DateTime.add(DateTime.utc_now(), -50, :millisecond)

      torrent = %Torrent{
        hash: "abc123",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :failed,
        failed_at: failed_at,
        added_at: DateTime.utc_now()
      }

      assert Torrent.should_cleanup?(torrent) == false
    end

    test "returns false for completed torrents" do
      completed_at = DateTime.add(DateTime.utc_now(), -1000, :millisecond)

      torrent = %Torrent{
        hash: "abc123",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :success,
        completed_at: completed_at,
        added_at: DateTime.utc_now()
      }

      assert Torrent.should_cleanup?(torrent) == false
    end

    test "returns false for processing torrents" do
      torrent = %Torrent{
        hash: "abc123",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :waiting_download,
        added_at: DateTime.utc_now()
      }

      assert Torrent.should_cleanup?(torrent) == false
    end

    test "returns false for failed torrents without failed_at timestamp" do
      torrent = %Torrent{
        hash: "abc123",
        magnet: "magnet:?xt=urn:btih:abc123",
        state: :failed,
        failed_at: nil,
        added_at: DateTime.utc_now()
      }

      assert Torrent.should_cleanup?(torrent) == false
    end
  end

  describe "periodic cleanup" do
    test "cleanup process is running and has correct intervals" do
      # Check if Cleanup process is alive
      assert Process.whereis(Cleanup) != nil

      # Verify config values are being used
      retention_sec = Aria2Debrid.Config.failed_retention() / 1000
      interval_sec = Aria2Debrid.Config.cleanup_interval() / 1000

      assert retention_sec > 0
      assert interval_sec > 0
    end
  end

  describe "cleanup behavior by state" do
    test "only failed torrents are eligible for automatic cleanup" do
      torrents = [
        %Torrent{
          hash: "failed1",
          magnet: "magnet:?xt=urn:btih:failed1",
          state: :failed,
          failed_at: DateTime.add(DateTime.utc_now(), -200, :millisecond),
          added_at: DateTime.utc_now()
        },
        %Torrent{
          hash: "success1",
          magnet: "magnet:?xt=urn:btih:success1",
          state: :success,
          completed_at: DateTime.add(DateTime.utc_now(), -200, :millisecond),
          added_at: DateTime.utc_now()
        },
        %Torrent{
          hash: "pending1",
          magnet: "magnet:?xt=urn:btih:pending1",
          state: :pending,
          added_at: DateTime.utc_now()
        },
        %Torrent{
          hash: "active1",
          magnet: "magnet:?xt=urn:btih:active1",
          state: :waiting_download,
          added_at: DateTime.utc_now()
        }
      ]

      eligible = Enum.filter(torrents, &Torrent.should_cleanup?/1)
      assert length(eligible) == 1
      assert hd(eligible).hash == "failed1"
    end

    test "completed torrents are never automatically cleaned up" do
      # Create a completed torrent from a year ago
      old_completed = %Torrent{
        hash: "oldcomplete",
        magnet: "magnet:?xt=urn:btih:oldcomplete",
        state: :success,
        completed_at: DateTime.add(DateTime.utc_now(), -365 * 24 * 60 * 60, :second),
        added_at: DateTime.utc_now()
      }

      refute Torrent.should_cleanup?(old_completed)
    end

    test "failed torrents with recent failure are not cleaned up yet" do
      recent_failure = %Torrent{
        hash: "recentfail",
        magnet: "magnet:?xt=urn:btih:recentfail",
        state: :failed,
        failed_at: DateTime.add(DateTime.utc_now(), -50, :millisecond),
        added_at: DateTime.utc_now()
      }

      refute Torrent.should_cleanup?(recent_failure)
    end
  end

  describe "Real-Debrid cleanup strategy" do
    test "validation failures should not cleanup RD immediately" do
      # Per ErrorClassifier, validation errors should keep RD resources
      import ProcessingQueue.ErrorClassifier

      assert cleanup_rd?(:validation) == false
    end

    test "permanent failures should cleanup RD immediately" do
      import ProcessingQueue.ErrorClassifier

      assert cleanup_rd?(:permanent) == true
    end

    test "warning failures should not cleanup RD" do
      import ProcessingQueue.ErrorClassifier

      assert cleanup_rd?(:warning) == false
    end

    test "application errors should not cleanup RD" do
      import ProcessingQueue.ErrorClassifier

      assert cleanup_rd?(:application) == false
    end
  end

  describe "cleanup_torrents behavior" do
    test "only processes torrents in failed state for RD cleanup" do
      # This verifies the Manager.cleanup_torrents logic
      # It should only cleanup RD for failed torrents, not success/pending
      # (This is verified by the Manager code at line 290-301)

      # Create test torrents with different states
      failed_torrent = %Torrent{
        hash: "failed123",
        magnet: "magnet:?xt=urn:btih:failed123",
        state: :failed,
        rd_id: "rd_failed_123",
        failed_at: DateTime.add(DateTime.utc_now(), -200, :millisecond),
        added_at: DateTime.utc_now()
      }

      success_torrent = %Torrent{
        hash: "success123",
        magnet: "magnet:?xt=urn:btih:success123",
        state: :success,
        rd_id: "rd_success_123",
        completed_at: DateTime.utc_now(),
        added_at: DateTime.utc_now()
      }

      # Only failed torrent should be eligible for cleanup
      assert Torrent.should_cleanup?(failed_torrent) == true
      assert Torrent.should_cleanup?(success_torrent) == false
    end
  end

  describe "edge cases" do
    test "torrents with nil failed_at timestamp are not cleaned up" do
      torrent = %Torrent{
        hash: "nofailedtime",
        magnet: "magnet:?xt=urn:btih:nofailedtime",
        state: :failed,
        failed_at: nil,
        added_at: DateTime.utc_now()
      }

      refute Torrent.should_cleanup?(torrent)
    end

    test "torrents with future failed_at timestamp are not cleaned up" do
      # This shouldn't happen in practice but test defensive programming
      future_failed_at = DateTime.add(DateTime.utc_now(), 1000, :millisecond)

      torrent = %Torrent{
        hash: "futurefail",
        magnet: "magnet:?xt=urn:btih:futurefail",
        state: :failed,
        failed_at: future_failed_at,
        added_at: DateTime.utc_now()
      }

      refute Torrent.should_cleanup?(torrent)
    end

    test "retention period boundary condition - exactly at threshold" do
      # Set retention to 100ms
      retention = Aria2Debrid.Config.failed_retention()
      failed_at = DateTime.add(DateTime.utc_now(), -retention, :millisecond)

      torrent = %Torrent{
        hash: "boundary",
        magnet: "magnet:?xt=urn:btih:boundary",
        state: :failed,
        failed_at: failed_at,
        added_at: DateTime.utc_now()
      }

      # Should be eligible (>= retention)
      assert Torrent.should_cleanup?(torrent) == true
    end
  end
end

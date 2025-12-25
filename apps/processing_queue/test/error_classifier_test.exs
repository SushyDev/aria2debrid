defmodule ProcessingQueue.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias ProcessingQueue.ErrorClassifier

  doctest ErrorClassifier

  describe "classify/1 - validation errors" do
    test "classifies file count mismatch as validation" do
      assert ErrorClassifier.classify("File count mismatch: expected 10, got 8") == :validation
      assert ErrorClassifier.classify("expected 5 files but got 3") == :validation
    end

    test "classifies media validation failures as validation" do
      assert ErrorClassifier.classify("media validation failed") == :validation
      assert ErrorClassifier.classify("Media Validation Failed") == :validation
      assert ErrorClassifier.classify("validation failed: no video stream") == :validation
    end

    test "classifies ffprobe failures as validation" do
      assert ErrorClassifier.classify("ffprobe failed to validate") == :validation
      assert ErrorClassifier.classify("FFprobe check failed") == :validation
    end

    test "classifies sample files as validation" do
      assert ErrorClassifier.classify("Sample file detected") == :validation
      assert ErrorClassifier.classify("file is a sample") == :validation
    end

    test "classifies missing streams as validation" do
      assert ErrorClassifier.classify("no video stream found") == :validation
      assert ErrorClassifier.classify("missing video stream") == :validation
      assert ErrorClassifier.classify("no audio stream") == :validation
      assert ErrorClassifier.classify("Missing audio stream") == :validation
    end

    test "classifies path not found as validation" do
      assert ErrorClassifier.classify("path not found") == :validation
      assert ErrorClassifier.classify("file does not exist") == :validation
      assert ErrorClassifier.classify("File not found") == :validation
    end

    test "classifies invalid media as validation" do
      assert ErrorClassifier.classify("invalid media file") == :validation
      assert ErrorClassifier.classify("corrupt file detected") == :validation
    end
  end

  describe "classify/1 - permanent errors" do
    test "classifies Real-Debrid API errors as permanent" do
      assert ErrorClassifier.classify("Real-Debrid API error: 503") == :permanent
      assert ErrorClassifier.classify("RD API failed") == :permanent
      assert ErrorClassifier.classify("api error from real debrid") == :permanent
    end

    test "classifies network errors as permanent" do
      assert ErrorClassifier.classify("network timeout") == :permanent
      assert ErrorClassifier.classify("connection failed") == :permanent
      assert ErrorClassifier.classify("Network error occurred") == :permanent
    end

    test "classifies invalid magnets as permanent" do
      assert ErrorClassifier.classify("invalid magnet link") == :permanent
      assert ErrorClassifier.classify("bad magnet URI") == :permanent
    end

    test "classifies torrent unavailable as permanent" do
      assert ErrorClassifier.classify("torrent unavailable") == :permanent
      assert ErrorClassifier.classify("Torrent not found on RD") == :permanent
      assert ErrorClassifier.classify("dead torrent") == :permanent
    end

    test "classifies account errors as permanent" do
      assert ErrorClassifier.classify("insufficient credits") == :permanent
      assert ErrorClassifier.classify("account limit reached") == :permanent
    end

    test "classifies HTTP errors as permanent" do
      assert ErrorClassifier.classify("HTTP error: status 500") == :permanent
      assert ErrorClassifier.classify("status 503 received") == :permanent
    end
  end

  describe "classify/1 - warning errors" do
    test "classifies empty queue as warning" do
      assert ErrorClassifier.classify("queue empty") == :warning
      assert ErrorClassifier.classify("no queue items found") == :warning
      assert ErrorClassifier.classify("Queue not found") == :warning
    end

    test "classifies missing credentials as warning" do
      assert ErrorClassifier.classify("credentials not provided") == :warning
      assert ErrorClassifier.classify("api key missing") == :warning
      assert ErrorClassifier.classify("missing servarr credentials") == :warning
    end

    test "classifies servarr unavailable as warning" do
      assert ErrorClassifier.classify("servarr unavailable") == :warning
      assert ErrorClassifier.classify("Sonarr timeout") == :warning
      assert ErrorClassifier.classify("servarr 503 error") == :warning
      assert ErrorClassifier.classify("servarr failed to respond") == :warning
    end

    test "classifies temporary failures as warning" do
      assert ErrorClassifier.classify("temporary failure, retry later") == :warning
      assert ErrorClassifier.classify("transient error") == :warning
    end
  end

  describe "classify/1 - application errors" do
    test "classifies ffmpeg not found as application" do
      assert ErrorClassifier.classify("ffmpeg not found") == :application
      assert ErrorClassifier.classify("ffprobe not found in PATH") == :application
      assert ErrorClassifier.classify("ffmpeg missing from system") == :application
    end

    test "classifies missing env vars as application" do
      assert ErrorClassifier.classify("environment variable required") == :application
      assert ErrorClassifier.classify("missing env: REAL_DEBRID_TOKEN") == :application
    end

    test "classifies invalid config as application" do
      assert ErrorClassifier.classify("invalid configuration detected") == :application
      assert ErrorClassifier.classify("config error: bad value") == :application
    end

    test "classifies system dependencies as application" do
      assert ErrorClassifier.classify("dependency not found") == :application
      assert ErrorClassifier.classify("system error: missing library") == :application
    end
  end

  describe "classify/1 - atom input" do
    test "classifies atom errors" do
      assert ErrorClassifier.classify(:file_count_mismatch) == :validation
      assert ErrorClassifier.classify(:network_timeout) == :permanent
      assert ErrorClassifier.classify(:queue_empty) == :warning
      assert ErrorClassifier.classify(:ffmpeg_not_found) == :application
    end
  end

  describe "classify/1 - exception input" do
    test "classifies exception structs" do
      error = %RuntimeError{message: "ffmpeg not found"}
      assert ErrorClassifier.classify(error) == :application

      error = %RuntimeError{message: "File count mismatch"}
      assert ErrorClassifier.classify(error) == :validation
    end
  end

  describe "classify/1 - map input" do
    test "classifies map with error key" do
      assert ErrorClassifier.classify(%{error: "file count mismatch"}) == :validation
    end

    test "classifies map with message key" do
      assert ErrorClassifier.classify(%{message: "Real-Debrid API error"}) == :permanent
    end

    test "classifies map with reason key" do
      assert ErrorClassifier.classify(%{reason: "queue empty"}) == :warning
    end

    test "classifies unknown map as permanent" do
      assert ErrorClassifier.classify(%{unknown: "error"}) == :permanent
    end
  end

  describe "classify/1 - unknown errors" do
    test "classifies unknown string errors as permanent" do
      assert ErrorClassifier.classify("completely unknown error") == :permanent
    end

    test "classifies unknown types as permanent" do
      assert ErrorClassifier.classify(123) == :permanent
      assert ErrorClassifier.classify([:list]) == :permanent
      assert ErrorClassifier.classify({:tuple}) == :permanent
    end
  end

  describe "aria2_error_code/1" do
    test "returns 24 for validation errors" do
      assert ErrorClassifier.aria2_error_code(:validation) == 24
    end

    test "returns 1 for permanent errors" do
      assert ErrorClassifier.aria2_error_code(:permanent) == 1
    end

    test "returns nil for warnings" do
      assert ErrorClassifier.aria2_error_code(:warning) == nil
    end

    test "returns nil for application errors" do
      assert ErrorClassifier.aria2_error_code(:application) == nil
    end
  end

  describe "notify_servarr?/1" do
    test "returns true only for validation errors" do
      assert ErrorClassifier.notify_servarr?(:validation) == true
      assert ErrorClassifier.notify_servarr?(:permanent) == false
      assert ErrorClassifier.notify_servarr?(:warning) == false
      assert ErrorClassifier.notify_servarr?(:application) == false
    end
  end

  describe "cleanup_rd?/1" do
    test "returns true only for permanent errors" do
      assert ErrorClassifier.cleanup_rd?(:validation) == false
      assert ErrorClassifier.cleanup_rd?(:permanent) == true
      assert ErrorClassifier.cleanup_rd?(:warning) == false
      assert ErrorClassifier.cleanup_rd?(:application) == false
    end
  end

  describe "should_raise?/1" do
    test "returns true only for application errors" do
      assert ErrorClassifier.should_raise?(:validation) == false
      assert ErrorClassifier.should_raise?(:permanent) == false
      assert ErrorClassifier.should_raise?(:warning) == false
      assert ErrorClassifier.should_raise?(:application) == true
    end
  end

  describe "describe/1" do
    test "returns description for validation" do
      desc = ErrorClassifier.describe(:validation)
      assert String.contains?(desc, "Validation")
      assert String.contains?(desc, "24")
    end

    test "returns description for permanent" do
      desc = ErrorClassifier.describe(:permanent)
      assert String.contains?(desc, "Permanent")
      assert String.contains?(desc, "1")
    end

    test "returns description for warning" do
      desc = ErrorClassifier.describe(:warning)
      assert String.contains?(desc, "warning")
      assert String.contains?(desc, "stalled")
    end

    test "returns description for application" do
      desc = ErrorClassifier.describe(:application)
      assert String.contains?(desc, "Configuration")
      assert String.contains?(desc, "admin")
    end
  end

  describe "handling_strategy/2" do
    test "returns complete strategy for validation error" do
      strategy = ErrorClassifier.handling_strategy(:validation, "File count mismatch")

      assert strategy.type == :validation
      assert strategy.error == "File count mismatch"
      assert strategy.aria2_error_code == 24
      assert strategy.cleanup_rd == false
      assert strategy.notify_servarr == true
      assert strategy.raise_exception == false
      assert is_binary(strategy.description)
    end

    test "returns complete strategy for permanent error" do
      strategy = ErrorClassifier.handling_strategy(:permanent, "Network timeout")

      assert strategy.type == :permanent
      assert strategy.aria2_error_code == 1
      assert strategy.cleanup_rd == true
      assert strategy.notify_servarr == false
      assert strategy.raise_exception == false
    end

    test "returns complete strategy for warning" do
      strategy = ErrorClassifier.handling_strategy(:warning, "Queue empty")

      assert strategy.type == :warning
      assert strategy.aria2_error_code == nil
      assert strategy.cleanup_rd == false
      assert strategy.notify_servarr == false
      assert strategy.raise_exception == false
    end

    test "returns complete strategy for application error" do
      strategy = ErrorClassifier.handling_strategy(:application, "ffmpeg not found")

      assert strategy.type == :application
      assert strategy.aria2_error_code == nil
      assert strategy.cleanup_rd == false
      assert strategy.notify_servarr == false
      assert strategy.raise_exception == true
    end
  end

  describe "log_classification/2" do
    test "logs error classification and returns type" do
      type = ErrorClassifier.log_classification("File count mismatch", %{hash: "abc123"})
      assert type == :validation
    end

    test "accepts empty context" do
      type = ErrorClassifier.log_classification("Network error")
      assert type == :permanent
    end
  end

  describe "edge cases" do
    test "classifies empty string as permanent" do
      assert ErrorClassifier.classify("") == :permanent
    end

    test "classifies whitespace as permanent" do
      assert ErrorClassifier.classify("   ") == :permanent
    end

    test "handles mixed case errors" do
      assert ErrorClassifier.classify("FILE COUNT MISMATCH") == :validation
      assert ErrorClassifier.classify("RealDebrid API Error") == :permanent
      assert ErrorClassifier.classify("Queue Empty") == :warning
      assert ErrorClassifier.classify("FFmpeg Not Found") == :application
    end

    test "handles errors with multiple patterns" do
      # Should match application pattern first (more specific)
      assert ErrorClassifier.classify("ffmpeg not found: network error") == :application

      # Should match validation pattern
      assert ErrorClassifier.classify("Real-Debrid: file count mismatch") == :validation
    end
  end

  describe "integration - full error handling flow" do
    test "validation error flow" do
      error = "File count mismatch: expected 10, got 8"
      type = ErrorClassifier.classify(error)

      assert type == :validation
      assert ErrorClassifier.aria2_error_code(type) == 24
      assert ErrorClassifier.notify_servarr?(type) == true
      assert ErrorClassifier.cleanup_rd?(type) == false
      assert ErrorClassifier.should_raise?(type) == false
    end

    test "permanent error flow" do
      error = "Real-Debrid API error: 503"
      type = ErrorClassifier.classify(error)

      assert type == :permanent
      assert ErrorClassifier.aria2_error_code(type) == 1
      assert ErrorClassifier.notify_servarr?(type) == false
      assert ErrorClassifier.cleanup_rd?(type) == true
      assert ErrorClassifier.should_raise?(type) == false
    end

    test "warning error flow" do
      error = "Servarr queue empty"
      type = ErrorClassifier.classify(error)

      assert type == :warning
      assert ErrorClassifier.aria2_error_code(type) == nil
      assert ErrorClassifier.notify_servarr?(type) == false
      assert ErrorClassifier.cleanup_rd?(type) == false
      assert ErrorClassifier.should_raise?(type) == false
    end

    test "application error flow" do
      error = "ffmpeg not found in PATH"
      type = ErrorClassifier.classify(error)

      assert type == :application
      assert ErrorClassifier.aria2_error_code(type) == nil
      assert ErrorClassifier.notify_servarr?(type) == false
      assert ErrorClassifier.cleanup_rd?(type) == false
      assert ErrorClassifier.should_raise?(type) == true
    end
  end
end

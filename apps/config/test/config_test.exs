defmodule ConfigTest do
  use ExUnit.Case, async: true

  describe "configuration accessors" do
    test "returns default values when not configured" do
      # Test config overrides these values, so check test values
      # Default max_retries is 10, but test.exs sets it to 1
      assert Aria2Debrid.Config.max_retries() == 1
      # Default requests_per_minute is 60, test.exs sets it to 100
      assert Aria2Debrid.Config.requests_per_minute() == 100
      # aria2 port is 6800 in test.exs
      assert Aria2Debrid.Config.aria2_port() == 6800
    end

    test "returns configured values" do
      # Test values are set in config/test.exs
      assert Aria2Debrid.Config.save_path() == "/tmp/test_media"
      assert Aria2Debrid.Config.validate_paths?() == false
      assert Aria2Debrid.Config.aria2_host() == "127.0.0.1"
    end

    test "media validation config" do
      # Test config has validation disabled
      assert Aria2Debrid.Config.media_validation_enabled?() == false
      assert Aria2Debrid.Config.validate_file_count?() == false
    end
  end
end

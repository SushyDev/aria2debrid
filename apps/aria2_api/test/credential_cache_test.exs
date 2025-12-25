defmodule Aria2Api.CredentialCacheTest do
  @moduledoc """
  Tests for the CredentialCache GenServer.
  """
  use ExUnit.Case, async: false

  alias Aria2Api.CredentialCache

  # Note: Tests run against the shared cache instance started by the application.
  # This means tests must use unique credentials to avoid conflicts.

  describe "validated?/1" do
    test "returns false for uncached credentials" do
      refute CredentialCache.validated?({"http://test1.example.com", "test-key-1"})
    end

    test "returns true for cached credentials" do
      creds = {"http://test2.example.com", "test-key-2"}
      CredentialCache.mark_validated(creds)

      assert CredentialCache.validated?(creds)
    end

    test "is case-insensitive for URLs" do
      creds1 = {"http://test3.example.com", "test-key-3"}
      creds2 = {"HTTP://TEST3.EXAMPLE.COM", "test-key-3"}

      CredentialCache.mark_validated(creds1)

      assert CredentialCache.validated?(creds2)
    end

    test "strips trailing slashes from URLs" do
      creds1 = {"http://test4.example.com", "test-key-4"}
      creds2 = {"http://test4.example.com/", "test-key-4"}

      CredentialCache.mark_validated(creds1)

      assert CredentialCache.validated?(creds2)
    end

    test "treats different API keys as separate entries" do
      creds1 = {"http://test5.example.com", "key-5a"}
      creds2 = {"http://test5.example.com", "key-5b"}

      CredentialCache.mark_validated(creds1)

      assert CredentialCache.validated?(creds1)
      refute CredentialCache.validated?(creds2)
    end

    test "treats different URLs as separate entries" do
      creds1 = {"http://test6a.example.com", "test-key-6"}
      creds2 = {"http://test6b.example.com", "test-key-6"}

      CredentialCache.mark_validated(creds1)

      assert CredentialCache.validated?(creds1)
      refute CredentialCache.validated?(creds2)
    end
  end

  describe "mark_validated/1" do
    test "caches credentials" do
      creds = {"http://test7.example.com", "test-key-7"}

      refute CredentialCache.validated?(creds)

      CredentialCache.mark_validated(creds)

      assert CredentialCache.validated?(creds)
    end

    test "is idempotent" do
      creds = {"http://test8.example.com", "test-key-8"}

      CredentialCache.mark_validated(creds)
      CredentialCache.mark_validated(creds)
      CredentialCache.mark_validated(creds)

      assert CredentialCache.validated?(creds)
    end
  end

  describe "stats/0" do
    test "returns stats with size and entries" do
      # Add a unique credential
      CredentialCache.mark_validated({"http://test9.example.com", "test-key-9"})

      stats = CredentialCache.stats()

      assert is_integer(stats.size)
      assert stats.size > 0
      assert is_list(stats.entries)
      assert length(stats.entries) == stats.size
    end

    test "entries are hashed for security" do
      CredentialCache.mark_validated({"http://test10.example.com", "secret-key-10"})

      stats = CredentialCache.stats()

      # Verify entries don't contain raw credentials
      assert length(stats.entries) > 0

      for entry <- stats.entries do
        refute entry =~ "secret"
        refute entry =~ "test10"
        # Should be a hex-encoded hash
        assert String.match?(entry, ~r/^[0-9a-f]{64}$/)
      end
    end
  end
end

defmodule ProcessingQueue.ErrorClassifier do
  @moduledoc """
  Classifies errors into categories for proper handling in the processing queue.

  ## Error Categories

  ### `:validation` - Validation Failures
  Triggers Sonarr/Radarr auto re-search. Maps to aria2 error code 24.

  Examples:
  - File count mismatch (expected vs actual)
  - Media validation failure (FFprobe checks)
  - Path validation failure (files don't exist)
  - Sample file detected
  - No video/audio stream found

  ### `:permanent` - Permanent Failures
  Does NOT trigger auto re-search. Maps to aria2 error code 1.

  Examples:
  - Real-Debrid API errors (500, 503, etc.)
  - Network timeouts
  - Invalid magnet links
  - Torrent unavailable/dead
  - RD account issues (insufficient credits)

  ### `:warning` - Non-Critical Issues
  Shows as stalled download (aria2 status="active" with progress=0).
  Does NOT fail the download or trigger re-search.

  Examples:
  - Servarr queue empty (timing issue, retry later)
  - Servarr API temporary failure (503, timeout)
  - No Servarr credentials provided (can't validate count)

  ### `:application` - Critical Configuration/System Errors
  Raises an exception instead of failing the download.
  Requires admin intervention to fix.

  Examples:
  - FFmpeg/FFprobe not installed
  - Missing required environment variables
  - Invalid configuration values
  - Critical system dependencies unavailable

  ## Usage

      iex> ErrorClassifier.classify("File count mismatch")
      :validation

      iex> ErrorClassifier.classify("Real-Debrid API error: 503")
      :permanent

      iex> ErrorClassifier.classify("Servarr queue empty")
      :warning

      iex> ErrorClassifier.classify("ffmpeg not found")
      :application

      iex> ErrorClassifier.aria2_error_code(:validation)
      24

      iex> ErrorClassifier.notify_servarr?(:validation)
      true

      iex> ErrorClassifier.cleanup_rd?(:permanent)
      true

      iex> ErrorClassifier.should_raise?(:application)
      true
  """

  require Logger

  @type error_type :: :validation | :permanent | :warning | :application

  # Error patterns for validation failures
  @validation_patterns [
    {:file_count_mismatch, ~r/file count|expected \d+ files/i},
    {:media_validation_failed, ~r/media validation|validation failed/i},
    {:ffprobe_failed, ~r/ffprobe.*failed/i},
    {:sample_file, ~r/sample/i},
    {:no_video_stream, ~r/no video stream|missing video/i},
    {:no_audio_stream, ~r/no audio stream|missing audio/i},
    {:path_not_found, ~r/path not found|file does not exist|file not found/i},
    {:invalid_media, ~r/invalid.*media|corrupt/i}
  ]

  # Error patterns for permanent failures
  @permanent_patterns [
    {:rd_api_error, ~r/real.?debrid|rd api/i},
    {:network_error, ~r/network|connection.*failed/i},
    {:invalid_magnet, ~r/invalid magnet|bad magnet/i},
    {:torrent_unavailable, ~r/unavailable|torrent.*not found|dead torrent/i},
    {:rd_account_error, ~r/insufficient|credits|account/i},
    {:http_error, ~r/http.*error|status.*\d{3}/i}
  ]

  # Error patterns for warnings (checked before permanent to catch specific cases)
  @warning_patterns [
    {:queue_empty, ~r/queue.*empty|no queue items/i},
    {:queue_not_found, ~r/queue.*not found/i},
    {:no_credentials, ~r/credentials|api key|missing.*servarr/i},
    {:servarr_unavailable, ~r/(sonarr|radarr|servarr).*(unavailable|timeout|503|failed)/i},
    {:temporary_failure, ~r/temporary|retry|transient/i}
  ]

  # Error patterns for application errors
  @application_patterns [
    {:ffmpeg_not_found, ~r/ffmpeg.*not found|ffprobe.*not found|ffmpeg.*missing/i},
    {:missing_env_var, ~r/environment variable.*required|missing.*env/i},
    {:invalid_config, ~r/invalid configuration|config.*error/i},
    {:system_dependency, ~r/dependency.*not found|system.*error/i}
  ]

  @doc """
  Classifies an error into one of four categories: :validation, :permanent, :warning, or :application.

  ## Parameters
    - `error` - Error to classify (string, atom, or exception struct)

  ## Returns
    - `:validation` - Validation failure (triggers Sonarr re-search)
    - `:permanent` - Permanent failure (no retry)
    - `:warning` - Non-critical issue (shows as stalled)
    - `:application` - System/config error (requires admin action)

  ## Examples

      iex> ErrorClassifier.classify("File count mismatch: expected 10, got 8")
      :validation

      iex> ErrorClassifier.classify("Real-Debrid API error: 503")
      :permanent

      iex> ErrorClassifier.classify(%RuntimeError{message: "ffmpeg not found"})
      :application

      iex> ErrorClassifier.classify(:queue_empty)
      :warning
  """
  @spec classify(term()) :: error_type()
  def classify(error) when is_binary(error) do
    cond do
      matches_any?(error, @application_patterns) -> :application
      matches_any?(error, @validation_patterns) -> :validation
      matches_any?(error, @warning_patterns) -> :warning
      matches_any?(error, @permanent_patterns) -> :permanent
      # Default to permanent for unknown errors
      true -> :permanent
    end
  end

  def classify(error) when is_atom(error) do
    error
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> classify()
  end

  def classify(%{__exception__: true, message: message}) when is_binary(message) do
    classify(message)
  end

  def classify(%{__exception__: true} = exception) do
    exception
    |> Exception.message()
    |> classify()
  end

  def classify(error) when is_map(error) do
    # Try to extract error message from map
    cond do
      Map.has_key?(error, :error) -> classify(error.error)
      Map.has_key?(error, :message) -> classify(error.message)
      Map.has_key?(error, :reason) -> classify(error.reason)
      true -> :permanent
    end
  end

  def classify(_error), do: :permanent

  @doc """
  Returns the aria2 error code for a given error type.

  ## Parameters
    - `type` - Error type (:validation, :permanent, :warning, or :application)

  ## Returns
    - `24` for validation errors (triggers Sonarr Failed Download Handler)
    - `1` for permanent errors (generic error, no retry)
    - `nil` for warnings and application errors (no error code)

  ## Examples

      iex> ErrorClassifier.aria2_error_code(:validation)
      24

      iex> ErrorClassifier.aria2_error_code(:permanent)
      1

      iex> ErrorClassifier.aria2_error_code(:warning)
      nil

      iex> ErrorClassifier.aria2_error_code(:application)
      nil
  """
  @spec aria2_error_code(error_type()) :: 1 | 24 | nil
  # HTTP error - triggers Sonarr FDH
  def aria2_error_code(:validation), do: 24
  # Unknown error - no retry
  def aria2_error_code(:permanent), do: 1
  # Not an error, shows as active
  def aria2_error_code(:warning), do: nil
  # Shouldn't reach aria2 API
  def aria2_error_code(:application), do: nil

  @doc """
  Determines if Sonarr should be notified about this error type via the API.

  Only validation errors trigger Sonarr notifications (if configured).

  ## Parameters
    - `type` - Error type

  ## Returns
    - `true` if Sonarr should be notified
    - `false` otherwise

  ## Examples

      iex> ErrorClassifier.notify_servarr?(:validation)
      true

      iex> ErrorClassifier.notify_servarr?(:permanent)
      false

      iex> ErrorClassifier.notify_servarr?(:warning)
      false
  """
  @spec notify_servarr?(error_type()) :: boolean()
  def notify_servarr?(:validation), do: true
  def notify_servarr?(_), do: false

  @doc """
  Determines if Real-Debrid resources should be cleaned up immediately for this error type.

  Validation errors keep the torrent in RD so Sonarr can see the error.
  Permanent errors clean up immediately.
  Warnings keep the torrent for potential recovery.
  Application errors don't cleanup (waiting for fix).

  ## Parameters
    - `type` - Error type

  ## Returns
    - `true` if RD should be cleaned up immediately
    - `false` if RD torrent should be kept

  ## Examples

      iex> ErrorClassifier.cleanup_rd?(:validation)
      false

      iex> ErrorClassifier.cleanup_rd?(:permanent)
      true

      iex> ErrorClassifier.cleanup_rd?(:warning)
      false

      iex> ErrorClassifier.cleanup_rd?(:application)
      false
  """
  @spec cleanup_rd?(error_type()) :: boolean()
  def cleanup_rd?(:permanent), do: true
  def cleanup_rd?(_), do: false

  @doc """
  Determines if this error should be raised as an exception instead of failing the download.

  Application errors require admin intervention and should stop processing,
  not mark the download as failed.

  ## Parameters
    - `type` - Error type

  ## Returns
    - `true` if error should be raised as exception
    - `false` if error should be handled normally

  ## Examples

      iex> ErrorClassifier.should_raise?(:application)
      true

      iex> ErrorClassifier.should_raise?(:validation)
      false

      iex> ErrorClassifier.should_raise?(:permanent)
      false
  """
  @spec should_raise?(error_type()) :: boolean()
  def should_raise?(:application), do: true
  def should_raise?(_), do: false

  @doc """
  Returns human-readable description of error type.

  ## Parameters
    - `type` - Error type

  ## Returns
    - String description of error type and handling

  ## Examples

      iex> ErrorClassifier.describe(:validation)
      "Validation failure - triggers Sonarr auto re-search (error code 24)"

      iex> ErrorClassifier.describe(:permanent)
      "Permanent failure - no automatic retry (error code 1)"
  """
  @spec describe(error_type()) :: String.t()
  def describe(:validation),
    do: "Validation failure - triggers Sonarr auto re-search (error code 24)"

  def describe(:permanent),
    do: "Permanent failure - no automatic retry (error code 1)"

  def describe(:warning),
    do: "Non-critical warning - shows as stalled, no failure"

  def describe(:application),
    do: "Configuration/system error - requires admin intervention"

  # Private helper functions

  defp matches_any?(string, patterns) do
    Enum.any?(patterns, fn {_name, pattern} ->
      String.match?(string, pattern)
    end)
  end

  @doc """
  Provides detailed error handling recommendations based on error type.

  ## Parameters
    - `type` - Error type
    - `error` - Original error message

  ## Returns
    - Map with handling recommendations

  ## Examples

      iex> strategy = ErrorClassifier.handling_strategy(:validation, "File count mismatch")
      iex> strategy.type
      :validation
      iex> strategy.aria2_error_code
      24
      iex> strategy.cleanup_rd
      false
      iex> strategy.notify_servarr
      true
      iex> strategy.raise_exception
      false
  """
  @spec handling_strategy(error_type(), term()) :: map()
  def handling_strategy(type, error) do
    %{
      type: type,
      error: error,
      aria2_error_code: aria2_error_code(type),
      cleanup_rd: cleanup_rd?(type),
      notify_servarr: notify_servarr?(type),
      raise_exception: should_raise?(type),
      description: describe(type)
    }
  end

  @doc """
  Logs error classification for debugging.

  ## Parameters
    - `error` - Error to classify and log
    - `context` - Optional context map for logging

  ## Returns
    - Error type
  """
  @spec log_classification(term(), map()) :: error_type()
  def log_classification(error, context \\ %{}) do
    type = classify(error)
    strategy = handling_strategy(type, error)

    Logger.info(
      "Error classified as #{inspect(type)}",
      error: inspect(error),
      strategy: inspect(strategy),
      context: inspect(context)
    )

    type
  end
end

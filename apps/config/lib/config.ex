defmodule Aria2Debrid.Config do
  @moduledoc """
  Configuration management for Aria2Debrid.

  Provides validated access to configuration values with sensible defaults.
  All configuration is read from the application environment.
  """

  @doc """
  Gets the Real Debrid API token.
  """
  @spec real_debrid_token() :: String.t() | nil
  def real_debrid_token do
    get_env(:processing_queue, :real_debrid_token)
  end

  @doc """
  Gets the rate limit for Real Debrid API requests per minute.
  """
  @spec requests_per_minute() :: pos_integer()
  def requests_per_minute do
    get_env(:processing_queue, :requests_per_minute, 60)
  end

  @doc """
  Gets the maximum number of retries for Real Debrid API requests.

  This is for the RealDebrid client library's automatic retry with exponential backoff
  for 429 (rate limit) and 5xx (server error) responses. The library already handles
  rate limiting proactively, so this is a fallback for when the API is overloaded.

  Default is 30 retries with exponential backoff (1s base delay, capped at 60s).
  """
  @spec max_retries() :: non_neg_integer()
  def max_retries do
    get_env(:processing_queue, :max_retries, 30)
  end

  @doc """
  Whether to select all files when adding torrents to Real Debrid.
  """
  @spec select_all?() :: boolean()
  def select_all? do
    get_env(:processing_queue, :select_all, false)
  end

  @doc """
  Additional file extensions to select (beyond video files).
  """
  @spec additional_selectable_files() :: [String.t()]
  def additional_selectable_files do
    get_env(:processing_queue, :additional_selectable_files, [
      "srt",
      "sub",
      "idx",
      "ass",
      "ssa",
      "smi",
      "vtt",
      "nfo",
      "jpg",
      "jpeg",
      "png",
      "tbn"
    ])
  end

  @doc """
  How long to retain failed torrents before cleanup (milliseconds).
  """
  @spec failed_retention() :: pos_integer()
  def failed_retention do
    get_env(:processing_queue, :failed_retention, :timer.minutes(5))
  end

  @doc """
  How often to run cleanup (milliseconds).
  """
  @spec cleanup_interval() :: pos_integer()
  def cleanup_interval do
    get_env(:processing_queue, :cleanup_interval, :timer.minutes(1))
  end

  @doc """
  Number of retries when fetching Servarr queue.
  """
  @spec queue_fetch_retries() :: non_neg_integer()
  def queue_fetch_retries do
    get_env(:processing_queue, :queue_fetch_retries, 5)
  end

  @doc """
  Timeout for waiting for torrent metadata (milliseconds).
  """
  @spec metadata_timeout() :: pos_integer()
  def metadata_timeout do
    get_env(:processing_queue, :metadata_timeout, :timer.minutes(2))
  end

  @doc """
  Number of retries for path validation.
  """
  @spec path_validation_retries() :: non_neg_integer()
  def path_validation_retries do
    get_env(:processing_queue, :path_validation_retries, 1000)
  end

  @doc """
  Delay between path validation retries (milliseconds).
  """
  @spec path_validation_delay() :: pos_integer()
  def path_validation_delay do
    get_env(:processing_queue, :path_validation_delay, :timer.seconds(10))
  end

  @doc """
  Port for the aria2 XML-RPC server.
  """
  @spec aria2_port() :: pos_integer()
  def aria2_port do
    get_env(:aria2_api, :port, 6800)
  end

  @doc """
  Host for the aria2 XML-RPC server.
  """
  @spec aria2_host() :: String.t()
  def aria2_host do
    get_env(:aria2_api, :host, "0.0.0.0")
  end

  @doc """
  RPC secret token for aria2 authentication.
  """
  @spec aria2_secret() :: String.t() | nil
  def aria2_secret do
    get_env(:aria2_api, :secret, nil)
  end

  @doc """
  Base save path for completed downloads.
  """
  @spec save_path() :: String.t()
  def save_path do
    get_env(:aria2_api, :save_path, "/mnt/debrid/media")
  end

  @doc """
  Whether to validate that paths exist on filesystem.
  """
  @spec validate_paths?() :: boolean()
  def validate_paths? do
    get_env(:aria2_api, :validate_paths, true)
  end

  @doc """
  Whether media validation is enabled.
  """
  @spec media_validation_enabled?() :: boolean()
  def media_validation_enabled? do
    get_env(:media_validator, :enabled, true)
  end

  @doc """
  Whether to validate file count matches expected.
  """
  @spec validate_file_count?() :: boolean()
  def validate_file_count? do
    get_env(:media_validator, :validate_file_count, true)
  end

  @doc """
  Whether to require files to be fully downloaded.
  """
  @spec require_downloaded?() :: boolean()
  def require_downloaded? do
    get_env(:media_validator, :require_downloaded, true)
  end

  @doc """
  List of streamable video file extensions.
  """
  @spec streamable_extensions() :: [String.t()]
  def streamable_extensions do
    get_env(:media_validator, :streamable_extensions, [
      "mkv",
      "mp4",
      "avi",
      "m4v",
      "mov",
      "wmv",
      "webm"
    ])
  end

  @doc """
  Minimum file size in bytes for valid media files.
  """
  @spec min_file_size_bytes() :: non_neg_integer()
  def min_file_size_bytes do
    get_env(:media_validator, :min_file_size_bytes, 500 * 1024 * 1024)
  end

  @doc """
  Whether to require a video stream in media files.
  """
  @spec require_video_stream?() :: boolean()
  def require_video_stream? do
    get_env(:media_validator, :require_video_stream, true)
  end

  @doc """
  Whether to require an audio stream in media files.
  """
  @spec require_audio_stream?() :: boolean()
  def require_audio_stream? do
    get_env(:media_validator, :require_audio_stream, true)
  end

  @doc """
  Whether to reject sample files.
  """
  @spec reject_sample_files?() :: boolean()
  def reject_sample_files? do
    get_env(:media_validator, :reject_sample_files, true)
  end

  @doc """
  Minimum runtime in seconds for a file to not be considered a sample.
  """
  @spec sample_min_runtime() :: pos_integer()
  def sample_min_runtime do
    get_env(:media_validator, :sample_min_runtime, 300)
  end

  @doc """
  Timeout for ffprobe commands (milliseconds).
  """
  @spec ffprobe_timeout() :: pos_integer()
  def ffprobe_timeout do
    get_env(:media_validator, :ffprobe_timeout, 30_000)
  end

  @doc """
  Whether to notify Servarr (Sonarr/Radarr) when validation fails.
  """
  @spec notify_servarr_on_failure?() :: boolean()
  def notify_servarr_on_failure? do
    get_env(:servarr_client, :notify_on_failure, false)
  end

  @doc """
  Whether to add failed releases to the blocklist in Servarr.
  """
  @spec servarr_blocklist_on_failure?() :: boolean()
  def servarr_blocklist_on_failure? do
    get_env(:servarr_client, :blocklist_on_failure, true)
  end

  @doc """
  Whether to trigger a new search after marking a download as failed.
  """
  @spec servarr_search_on_failure?() :: boolean()
  def servarr_search_on_failure? do
    get_env(:servarr_client, :search_on_failure, true)
  end

  defp get_env(app, key, default \\ nil) do
    Application.get_env(app, key, default)
  end
end

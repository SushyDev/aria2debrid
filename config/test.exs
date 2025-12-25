# Test config
import Config

# aria2 JSON-RPC API config
config :aria2_api,
  port: 6800,
  host: "127.0.0.1",
  secret: nil,
  save_path: "/tmp/test_media",
  validate_paths: false

# Processing queue config - faster timeouts for tests
config :processing_queue,
  real_debrid_token: "test_token",
  requests_per_minute: 100,
  max_retries: 1,
  select_all: false,
  additional_selectable_files: ["srt"],
  failed_retention: :timer.seconds(5),
  cleanup_interval: :timer.seconds(1),
  metadata_timeout: :timer.seconds(10),
  path_validation_delay: 100

# Media validation config - disabled for faster tests
config :media_validator,
  enabled: false,
  validate_file_count: false,
  require_downloaded: false,
  streamable_extensions: ["mkv", "mp4", "avi", "m4v", "mov", "wmv", "webm"],
  require_video_stream: false,
  require_audio_stream: false,
  reject_sample_files: false,
  ffprobe_timeout: 5_000

config :logger, level: :warning

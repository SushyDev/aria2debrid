# Development config
import Config

# aria2 JSON-RPC API config
config :aria2_api,
  port: 6801,
  host: "0.0.0.0",
  secret: nil,
  save_path: "/mnt/fvs/debrid_drive_ex/media_manager/",
  validate_paths: true

# Real Debrid and processing queue config
config :processing_queue,
  requests_per_minute: 60,
  max_retries: 30,
  select_all: false,
  additional_selectable_files: [
    # "srt",
    # "sub",
    # "idx",
    # "ass",
    # "ssa",
    # "smi",
    # "vtt",
    # "nfo",
    # "jpg",
    # "jpeg",
    # "png",
    # "tbn"
  ],
  # Automatic cleanup of failed downloads
  failed_retention: :timer.seconds(90),
  cleanup_interval: :timer.seconds(90),
  queue_fetch_retries: 5,
  metadata_timeout: :timer.minutes(2),
  path_validation_retries: 1000,
  path_validation_delay: :timer.seconds(10)

# Media validation config
config :media_validator,
  enabled: true,
  validate_file_count: true,
  require_downloaded: true,
  streamable_extensions: [
    "mkv",
    "mp4",
    "avi",
    "m4v",
    "mov",
    "wmv",
    "webm"
  ],
  require_video_stream: true,
  require_audio_stream: true,
  reject_sample_files: false,
  # 10 Minutes
  sample_min_runtime: 600,
  ffprobe_timeout: 30_000

config :logger, level: :debug

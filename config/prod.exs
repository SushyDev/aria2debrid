# Production compile-time config
import Config

# Automatic cleanup of failed downloads
config :processing_queue,
  failed_retention: :timer.minutes(15),
  cleanup_interval: :timer.minutes(15)

config :logger, level: :info

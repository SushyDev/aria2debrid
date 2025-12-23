# DebridDriveEx Configuration

# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# having access to `Mix.env()`.

import Config

# Configure logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :hash, :torrent_id]

# Import environment-specific config
import_config "#{config_env()}.exs"

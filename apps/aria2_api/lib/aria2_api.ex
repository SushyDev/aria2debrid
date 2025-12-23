defmodule Aria2Api do
  @moduledoc """
  aria2 XML-RPC API implementation for Sonarr/Radarr integration.

  This module provides a compatible aria2 XML-RPC API that allows Sonarr and Radarr
  to interact with our Real-Debrid-based download system as if it were an aria2
  instance.

  **IMPORTANT**: Sonarr/Radarr ONLY use XML-RPC (not JSON-RPC) for aria2 integration.

  ## Why aria2?

  aria2's error handling is well-suited for triggering Sonarr/Radarr's
  automatic re-search and blocklisting:
  - aria2 has explicit `error` status with error codes
  - Error codes map directly to failure reasons (code 24 = validation failure)
  - Sonarr/Radarr properly handle aria2's error states for triggering re-search

  ## Servarr Integration (Episode Count Detection)

  To enable episode count validation and automatic failure notifications,
  configure the **Directory** setting in Sonarr/Radarr's download client
  with your Servarr credentials:

      http://sonarr:8989|YOUR_API_KEY

  Format: `servarr_url|api_key` (pipe-delimited)

  This allows the system to:
  - Fetch expected file counts from the Servarr queue
  - Validate that season packs have the correct number of episodes
  - Notify Servarr when downloads fail validation
  - Trigger automatic re-search for alternative releases

  If no credentials are provided in the Directory field, episode count
  validation is skipped but all other features work normally.

  ## Sonarr/Radarr Configuration

  1. Add aria2 as a download client:
     - Host: your-server
     - Port: 6800 (default)
     - RPC Path: /jsonrpc
     - Secret Token: (optional, set via ARIA2_SECRET env var)
     - Directory: `http://sonarr:8989|YOUR_API_KEY` (see above)

  2. The system will automatically:
     - Accept magnet links from Sonarr/Radarr
     - Add them to Real Debrid
     - Report status back in aria2 format
     - Mark failed downloads with error codes that trigger re-search

  ## Supported XML-RPC Methods

  - `aria2.addUri` - Add download by magnet URI
  - `aria2.addTorrent` - Add download by torrent file (base64 encoded)
  - `aria2.tellStatus` - Get download status by GID
  - `aria2.tellActive` - List active downloads
  - `aria2.tellWaiting` - List waiting downloads
  - `aria2.tellStopped` - List stopped downloads
  - `aria2.remove` - Remove a download
  - `aria2.forceRemove` - Force remove a download
  - `aria2.pause` - Pause a download
  - `aria2.unpause` - Resume a paused download
  - `aria2.removeDownloadResult` - Remove completed/stopped download result
  - `aria2.getGlobalStat` - Get global statistics
  - `aria2.getVersion` - Get aria2 version
  - `aria2.getSessionInfo` - Get session info
  - `system.multicall` - Batch method calls
  - `system.listMethods` - List available methods

  ## GID System

  aria2 uses 16-character hex GIDs to identify downloads. We generate GIDs
  that map to our internal torrent hashes (first 16 chars of the infohash).

  ## Status Mapping

  ProcessingQueue states are mapped to aria2 statuses:
  - `:pending` → "waiting"
  - Processing states → "active" (downloading)
  - `:success` → "complete"
  - `:failed` with `:validation` → "error" (triggers re-search)
  - `:failed` with `:permanent` → "error"

  ## Error Codes

  aria2 error codes used for different failure types:
  - 1: Unknown error (permanent failures)
  - 24: HTTP/download error (validation failures - triggers re-search)

  ## Configuration

  Environment variables:
  - `ARIA2_PORT` - XML-RPC server port (default: 6800)
  - `ARIA2_HOST` - XML-RPC server host (default: "0.0.0.0")
  - `ARIA2_SECRET` - RPC secret token (optional)
  - `SAVE_PATH` - Base download directory
  """
end

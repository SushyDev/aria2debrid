# Runtime config (evaluated at runtime, not compile time)
import Config

if config_env() in [:dev, :prod] do
  # aria2 JSON-RPC API config
  config :aria2_api,
    port: String.to_integer(System.get_env("ARIA2_PORT") || System.get_env("PORT") || "6800"),
    host: System.get_env("ARIA2_HOST") || System.get_env("HOST") || "0.0.0.0",
    secret: System.get_env("ARIA2_SECRET")

  # Real Debrid config
  real_debrid_token =
    if config_env() == :prod do
      System.get_env("REAL_DEBRID_API_TOKEN") ||
        raise "REAL_DEBRID_API_TOKEN environment variable is required"
    else
      System.get_env("REAL_DEBRID_API_TOKEN")
    end

  if real_debrid_token do
    config :processing_queue,
      real_debrid_token: real_debrid_token
  end

  config :processing_queue,
    requests_per_minute:
      String.to_integer(System.get_env("REAL_DEBRID_REQUESTS_PER_MINUTE") || "60"),
    max_retries: String.to_integer(System.get_env("REAL_DEBRID_MAX_RETRIES") || "30"),
    select_all: System.get_env("REAL_DEBRID_SELECT_ALL") == "true",
    additional_selectable_files:
      (System.get_env("REAL_DEBRID_ADDITIONAL_FILES") ||
         "srt,sub,idx,ass,ssa,smi,vtt,nfo,jpg,jpeg,png,tbn")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

  # Media validation config
  config :media_validator,
    enabled: System.get_env("MEDIA_VALIDATION_ENABLED") != "false",
    validate_file_count: System.get_env("VALIDATE_FILE_COUNT") != "false",
    require_downloaded: System.get_env("REQUIRE_DOWNLOADED") != "false",
    streamable_extensions:
      (System.get_env("STREAMABLE_EXTENSIONS") || "mkv,mp4,avi,m4v,mov,wmv,webm")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

  # Save path config
  save_path =
    if config_env() == :prod do
      System.get_env("SAVE_PATH") ||
        raise "SAVE_PATH environment variable is required"
    else
      System.get_env("SAVE_PATH") || "/mnt/fvs/debrid_drive_ex/media_manager"
    end

  # aria2 API save path
  config :aria2_api,
    save_path: save_path,
    validate_paths: System.get_env("VALIDATE_PATHS") != "false"

  # Servarr integration config
  # By default, we rely on Sonarr's Failed Download Handling (FDH) to automatically
  # detect errors from aria2 and retry. Set NOTIFY_SERVARR_ON_FAILURE=true to
  # explicitly call the mark-as-failed API instead.
  config :servarr_client,
    notify_on_failure: System.get_env("NOTIFY_SERVARR_ON_FAILURE") == "true",
    blocklist_on_failure: System.get_env("BLOCKLIST_ON_FAILURE") == "true",
    search_on_failure: System.get_env("SEARCH_ON_FAILURE") == "true",
    history_lookback_days: String.to_integer(System.get_env("SERVARR_HISTORY_DAYS") || "7")
end

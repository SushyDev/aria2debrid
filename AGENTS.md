# Agent Guidelines for aria2debrid

## Project Overview

**aria2debrid** is an aria2 XML-RPC API implementation for Real-Debrid integration with Sonarr/Radarr. It provides an aria2-compatible download client interface that Sonarr/Radarr can use to download torrents via Real-Debrid's cached torrent system.

**Key Architecture Points:**
- Implements aria2's XML-RPC protocol (NOT JSON-RPC - Sonarr/Radarr only use XML-RPC)
- Async torrent processing with FSM (Finite State Machine) for state management
- Validates media files with FFprobe before marking as complete
- Handles Sonarr/Radarr Failed Download Handler integration via aria2 error codes

## Build/Test Commands
- **Run all tests**: `mix test`
- **Run single test**: `mix test apps/aria2_api/test/downloads_test.exs` or `mix test apps/aria2_api/test/downloads_test.exs:42` (specific line)
- **Format code**: `mix format`
- **Compile**: `mix compile`
- **Start dev server**: `iex -S mix` (interactive) or `mix run --no-halt`

## Code Style
- **Imports**: Use `alias` for modules (e.g., `alias ProcessingQueue.{Torrent, Manager}`), `require Logger` for macros
- **Formatting**: Run `mix format` before committing; follows `.formatter.exs` rules (120 char line length by default)
- **Moduledocs**: Every public module needs `@moduledoc` with description (see `apps/processing_queue/lib/processing_queue/processor.ex:1-9`)
- **Types**: Use `@type`, `@spec` for public functions; define custom types at top of module (see `apps/processing_queue/lib/processing_queue/torrent.ex`)
- **Naming**: `snake_case` for functions/variables, `CamelCase` for modules, `?` suffix for boolean functions (e.g., `validate_file_count?/0`)
- **Pattern matching**: Prefer pattern matching in function heads over conditionals when possible
- **Error handling**: Return `{:ok, result}` or `{:error, reason}` tuples; use `case` statements for error propagation
- **Logging**: Use `Logger.debug/info/warning/error` with structured messages including torrent hash when available
- **GenServers**: Use `via_tuple` pattern with Registry for named processes (see `apps/processing_queue/lib/processing_queue/processor.ex:23-25`)
- **State machines**: Document state flow in moduledoc (see `apps/processing_queue/lib/processing_queue/processor.ex:5-8`)

## Project Structure
- Umbrella app with apps in `apps/`: `aria2_api`, `config`, `media_validator`, `processing_queue`, `servarr_client`
- Config in `config/runtime.exs` (runtime) and `config/{dev,prod,test}.exs` (compile-time)

## Critical Architecture Decisions & Edge Cases

### 1. XML-RPC Only (No JSON-RPC)
**Decision**: Sonarr/Radarr only use XML-RPC, not JSON-RPC.
- The project originally had 200+ lines of dead JSON-RPC code that was removed
- All RPC handling goes through `/rpc` endpoint with XML-RPC encoding
- Do NOT add JSON-RPC support unless a real use case emerges

### 2. InfoHash Case Sensitivity
**Critical Edge Case** (see `apps/aria2_api/lib/aria2_api/handlers/downloads.ex:388-391`):
- **Sonarr DB queries are case-sensitive** for infohash matching
- **Must return UPPERCASE** infohash to Sonarr in aria2 status responses
- **Store lowercase internally** for rclone compatibility and Real-Debrid API
- Use `String.upcase(hash)` when building aria2 status, `String.downcase(hash)` when storing

### 3. Error Code Strategy for Sonarr Integration
**Decision** (see `apps/processing_queue/lib/processing_queue/error_classifier.ex`):

| Error Type | aria2 Error Code | Behavior | Real-Debrid Cleanup |
|------------|------------------|----------|---------------------|
| **Validation** (`file_count`, `media_validation`, `sample_file`) | `24` | Triggers Sonarr re-search via Failed Download Handler | Keep in RD (Sonarr may retry) |
| **Permanent** (`rd_api_error`, `network_timeout`, `invalid_magnet`) | `1` | No retry, shows as failed | Cleanup immediately |
| **Warning** (`empty_queue`, `missing_credentials`) | `nil` | Shows as "active" with 0% progress (appears stalled) | Keep in RD |
| **Application** (`ffmpeg_not_found`, `missing_env_var`) | `nil` | Raise exception, stop processing | Keep in RD |

**Key Points:**
- ErrorClassifier provides centralized error categorization with regex patterns
- Validation errors (code 24) = retryable, keep torrent for Sonarr to investigate
- Permanent errors (code 1) = non-retryable, cleanup resources immediately
- Warning errors = non-critical issues that shouldn't fail the download
- Application errors = configuration issues requiring admin intervention (should raise, not fail silently)

### 4. Multi-Tenant Support (Multiple Sonarr/Radarr Instances)
**Critical Decision** (see `apps/aria2_api/lib/aria2_api/router.ex`):

**Problem**: Without proper filtering, multiple Sonarr/Radarr instances would see each other's downloads in the Activity queue, leading to confusion and potential conflicts.

**Solution**: Map aria2 secrets to Servarr instances, then filter torrents by matching infohashes against each Servarr's grabbed history.

**Why Not HTTP Basic Auth?**
- Sonarr/Radarr's aria2 client doesn't support HTTP Basic Auth configuration
- Only available fields are: Host, Port, SecretToken, Directory, RpcPath, UseSsl
- We use unique secrets per Servarr instead

**Why History API Instead of URL Matching?**
- URLs can vary between requests (internal vs external, docker names vs IPs, HTTP vs HTTPS)
- Example: Same Sonarr could be `http://sonarr:8989`, `http://192.168.1.100:8989`, `https://sonarr.example.com`
- Infohashes are always consistent regardless of how the torrent was grabbed
- More reliable and handles complex networking setups

**Configuration**:

In Sonarr/Radarr Download Client Settings:
- **Host**: `aria2debrid.example.com`
- **Port**: `6800`
- **SecretToken**: `http://sonarr:8989|YOUR_SONARR_API_KEY`
- **Directory**: Leave empty
- **RpcPath**: `/rpc`
- **Use SSL**: Enable if using HTTPS

The SecretToken is parsed directly as `url|api_key` format. The pipe character `|` is used as delimiter since URLs contain colons.

**How It Works**:
- When Sonarr/Radarr makes a request:
  1. aria2debrid extracts the secret token from the request
  2. Parses it as `url|api_key` to get Servarr credentials
  3. Fetches that Servarr's grabbed history via `/api/v3/history?eventType=grabbed`
  4. Filters torrents to only show those whose infohash appears in that Servarr's grabbed history
  5. Returns filtered list (each Servarr only sees downloads it grabbed)

**Error Handling**:
- **No secret provided**: Returns empty list (enforces multi-tenant security)
- **Invalid secret format**: Returns empty list (enforces multi-tenant security)
- **History API call fails**: Returns empty list + error log (prevents cross-contamination)

**Key Points**:
- Credentials passed directly in SecretToken field as `url|api_key`
- Each Servarr instance uses unique credentials in their SecretToken
- Servarr URL can be any URL that reaches the Servarr API (internal/external)
- API key must be valid for the Servarr instance
- Prevents Sonarr from seeing Radarr's downloads and vice versa (via infohash filtering)
- Handles complex networking (internal/external, docker, proxies, etc.)
- **REQUIRED**: SecretToken must be configured, otherwise returns empty list (no downloads visible)
- Uses `/api/v3/history/since?eventType=grabbed` endpoint (simple, no pagination needed)

### 5. Torrent Completion Requirements
**Critical Decision**:
- Torrent NOT complete when Real-Debrid finishes downloading
- Torrent NOT complete after file count validation passes
- Torrent NOT complete after media validation passes
- **Torrent ONLY complete after ALL validation checks pass** → transitions to `:success` state
- This ensures Sonarr never imports incomplete/invalid files

**State Flow** (see `apps/processing_queue/lib/processing_queue/processor.ex:5-8`):
```
pending → adding_rd → waiting_metadata → selecting_files → 
waiting_download → validating_file_count → validating_media → 
validating_paths → success (or failed)
```

### 6. Status Reporting for Different States
**Mapping** (see `apps/aria2_api/lib/aria2_api/handlers/downloads.ex:369-402`):

| Torrent State | aria2 Status | completedLength | Notes |
|--------------|--------------|-----------------|-------|
| `pending` | `waiting` | 0 | Initial state |
| `adding_rd`, `waiting_metadata`, `selecting_files` | `waiting` | 0 | Pre-download states |
| `waiting_download`, `validating_*` | `active` | Based on RD progress | Shows as downloading/processing |
| `success` | `complete` | = totalLength | All validation passed |
| `failed` (validation) | `error` (code 24) | 0 | Triggers Sonarr re-search |
| `failed` (permanent) | `error` (code 1) | 0 | No retry |
| `failed` (warning) | `active` | 0 | Appears stalled |

**Key Point**: Warning failures show as "active" to prevent Sonarr from treating them as failed downloads.

### 7. Numeric Fields Must Be Strings
**aria2 XML-RPC Requirement**:
- All numeric fields MUST be returned as strings (not integers)
- Includes: `completedLength`, `totalLength`, `uploadLength`, `downloadSpeed`, `uploadSpeed`
- Use `Integer.to_string()` or `to_string()` when building responses
- Sonarr expects strings and will fail to parse integers

### 8. Media Validation Strategy
**Decision** (see `apps/media_validator/lib/media_validator.ex`):
- Use FFprobe to validate video/audio streams before marking complete
- Check for minimum file size to detect samples
- Validate file extensions match expected video formats
- Sample detection: filename patterns like "sample", "preview", "trailer"
- All validation happens via streaming links (before full download completes)

**Edge Cases**:
- FFmpeg/FFprobe missing = application error (should raise)
- Network timeout during validation = permanent error (should retry whole torrent)
- Invalid media = validation error (code 24, trigger re-search)

### 9. Real-Debrid Resource Cleanup
**Critical Decision**:
- **Validation failures**: Keep in Real-Debrid (Sonarr may need to inspect)
- **Permanent failures**: Delete from Real-Debrid immediately (save quota)
- **Warning failures**: Keep in Real-Debrid (may recover)
- Use `ErrorClassifier.cleanup_rd?/1` to determine cleanup strategy

### 10. State Machine Transitions
**Critical Rules**:
- State transitions are one-way (no backwards transitions except to `:failed`)
- Processor uses self-messaging pattern for async transitions
- Manager stores state, Processor executes transitions
- Terminal states: `:success`, `:failed`
- Use `Torrent.transition/2` to ensure `completed_at`/`failed_at` timestamps set correctly

### 11. GID Registry Pattern
**Decision** (see `apps/aria2_api/lib/aria2_api/gid_registry.ex`):
- GIDs are 16-character hex strings (like real aria2)
- Registry maps GID → torrent hash
- Allows aria2 methods to look up torrents by GID
- Use `GidRegistry.register/2` when adding torrents

### 12. File Selection from Torrents
**Edge Case**:
- Real-Debrid requires file selection for multi-file torrents
- Select video files + subtitle/metadata files (srt, sub, nfo, jpg, etc.)
- Filter by extension list from config
- Handle torrents without metadata (empty files array until RD provides info)

### 13. Automatic Cleanup of Failed Downloads
**Critical Decision** (see `apps/processing_queue/lib/processing_queue/cleanup.ex`):

**Sonarr's aria2 Client Limitation:**
- Sonarr's aria2 client ONLY sets `CanBeRemoved=true` for completed downloads (`status="complete"`)
- Failed downloads (`status="error"`) have `CanBeRemoved=false`
- **Even with `RemoveFailedDownloads=true`, Sonarr will NOT remove failed aria2 downloads**
- The `RemoveFailedDownloads` setting is effectively ignored for aria2 due to this limitation

**Sonarr's Failed Download Handler:**
1. Detects the failed download via aria2 status
2. Blocklists the release
3. Triggers a new search for alternatives
4. **Does NOT automatically remove the failed download from aria2** (due to CanBeRemoved limitation)

**Solution: Automatic Cleanup:**
- **Automatic cleanup enabled** with 5-minute retention period (configurable via `FAILED_RETENTION_MS`)
- Cleanup runs every 1 minute (configurable via `CLEANUP_INTERVAL_MS`)
- Without cleanup, failed downloads accumulate indefinitely in `aria2.tellStopped` results

**What Gets Cleaned:**
- Only torrents in `:failed` state that have been failed for >= retention period
- Both the torrent state in Manager AND the GID registry entry
- Real-Debrid resources for failed torrents are cleaned up immediately
- **Completed downloads (`:success` state) are NOT cleaned up automatically**
  - Sonarr WILL remove them via `aria2.removeDownloadResult` (if `RemoveCompletedDownloads=true`)
  - Real-Debrid resources remain available until explicitly removed
  - This allows Sonarr to control when completed downloads are cleaned up

**Real-Debrid Cleanup Strategy:**
- **Failed torrents removed by cleanup**: RD resources deleted
- **Failed torrents removed by Sonarr**: RD resources deleted
- **Completed torrents removed by Sonarr**: RD resources kept (user may want them available)
- **Manual removal via aria2.forceRemove**: RD resources deleted only if failed

**GID Registry Cleanup:**
- Manager calls `GidRegistry.unregister/1` for both `remove_torrent` and `cleanup_torrents`
- Uses module attribute `@gid_registry` to avoid circular compile-time dependency
- Gracefully handles `UndefinedFunctionError` if GidRegistry is not available (e.g., in tests)
- This prevents memory leak in the ETS-backed GID registry

## Testing Guidelines

### Current Test Coverage
- **111 total tests** across 5 apps
- XML-RPC compatibility tests in `apps/aria2_api/test/sonarr_compatibility_test.exs`
- ErrorClassifier has 84 tests covering all error categories
- No JSON-RPC tests (intentionally removed as dead code)

### Test Patterns
1. **Sonarr Compatibility**: Test actual XML-RPC messages Sonarr sends
2. **Error Classification**: Test pattern matching and error handling strategies
3. **State Transitions**: Test FSM state flow and terminal states
4. **Edge Cases**: Test infohash case sensitivity, missing credentials, empty queues

### Phase 1 Test Additions (Planned)
See `FSM_UPGRADE_PLAN.md` for comprehensive test suite additions:
- aria2 API response validation (aria2_add_torrent_test.exs, aria2_status_reporting_test.exs)
- Download lifecycle tests (failed_download_test.exs, completed_download_test.exs)
- Activity tracking tests (aria2_activity_test.exs)

## Common Pitfalls

1. **DON'T return integers in XML-RPC responses** - must be strings
2. **DON'T return lowercase infohash** - Sonarr DB is case-sensitive (use uppercase)
3. **DON'T add JSON-RPC code** - Sonarr/Radarr don't use it
4. **DON'T mark torrent complete before all validation passes** - Sonarr will import invalid files
5. **DON'T cleanup Real-Debrid for validation failures** - Sonarr needs to inspect
6. **DON'T fail silently on application errors** - raise exceptions for admin attention
7. **DON'T use hardcoded error messages** - use ErrorClassifier for consistent categorization
8. **DON'T transition backwards in FSM** - only forward to terminal states

## Reference Files

- **FSM Upgrade Plan**: `FSM_UPGRADE_PLAN.md` - Comprehensive architecture analysis and improvement plan
- **Error Classification**: `apps/processing_queue/lib/processing_queue/error_classifier.ex` - Central error handling
- **Sonarr Integration**: `apps/aria2_api/test/sonarr_compatibility_test.exs` - Real Sonarr XML-RPC examples
- **State Machine**: `apps/processing_queue/lib/processing_queue/processor.ex` - FSM implementation

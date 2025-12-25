defmodule ProcessingQueue.Validators.FileCountValidator do
  @moduledoc """
  Compares actual vs expected file counts.

  Validates that the number of selected video files matches or exceeds
  the expected count from Servarr history.

  ## Usage

      case FileCountValidator.validate(torrent) do
        :ok -> # Validation passed
        {:skip, reason} -> # Validation skipped (disabled or no credentials)
        {:error, reason} -> # Validation failed
      end
  """

  require Logger

  alias ProcessingQueue.{FileSelector, ServarrSync, Torrent}

  @doc """
  Validates file count for a torrent.

  ## Validation Logic

  1. Check if file count validation is enabled
  2. Verify Servarr credentials are available
  3. Fetch expected count from Servarr history
  4. Compare actual vs expected

  ## Returns
    - `:ok` - File count matches or exceeds expected
    - `{:skip, reason}` - Validation skipped (disabled or no credentials)
    - `{:error, :history_empty}` - No history entry found
    - `{:error, {:count_mismatch, expected, actual}}` - Count doesn't match
    - `{:error, reason}` - API or other error
  """
  @spec validate(Torrent.t()) :: :ok | {:skip, String.t()} | {:error, term()}
  def validate(%Torrent{} = torrent) do
    cond do
      not Aria2Debrid.Config.validate_file_count?() ->
        Logger.debug("File count validation disabled by config")
        {:skip, "File count validation disabled"}

      missing_credentials?(torrent) ->
        {:error, {:missing_credentials, "Servarr credentials required for file count validation"}}

      true ->
        do_validate(torrent)
    end
  end

  @doc """
  Gets the actual count of selected video files.
  """
  @spec actual_count(Torrent.t()) :: non_neg_integer()
  def actual_count(%Torrent{files: files}) when is_list(files) do
    FileSelector.count_selected_video_files(files)
  end

  def actual_count(_), do: 0

  @doc """
  Fetches expected file count from Servarr.

  ## Returns
    - `{:ok, count}` - Expected count retrieved
    - `{:error, :history_empty}` - No history entry
    - `{:error, reason}` - API error
  """
  @spec fetch_expected_count(Torrent.t()) :: {:ok, pos_integer()} | {:error, term()}
  def fetch_expected_count(%Torrent{
        servarr_url: url,
        servarr_api_key: api_key,
        hash: hash
      }) do
    ServarrSync.get_expected_file_count(url, api_key, hash)
  end

  # Private functions

  defp missing_credentials?(%Torrent{servarr_url: nil}), do: true
  defp missing_credentials?(%Torrent{servarr_url: ""}), do: true
  defp missing_credentials?(%Torrent{servarr_api_key: nil}), do: true
  defp missing_credentials?(%Torrent{servarr_api_key: ""}), do: true
  defp missing_credentials?(_), do: false

  defp do_validate(torrent) do
    # If expected_files is already set on torrent, use it
    # Otherwise fetch from Servarr
    case get_expected_count(torrent) do
      {:ok, expected} ->
        actual = actual_count(torrent)
        compare_counts(expected, actual)

      {:error, :history_empty} ->
        Logger.warning("No history entry found for #{torrent.hash}")
        {:error, :history_empty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_expected_count(%Torrent{expected_files: expected}) when is_integer(expected) do
    {:ok, expected}
  end

  defp get_expected_count(torrent) do
    fetch_expected_count(torrent)
  end

  defp compare_counts(expected, actual) when actual >= expected do
    Logger.info("File count validation passed: expected #{expected}, got #{actual}")
    :ok
  end

  defp compare_counts(expected, actual) do
    Logger.warning("File count mismatch: expected #{expected}, got #{actual}")
    {:error, {:count_mismatch, expected, actual}}
  end
end

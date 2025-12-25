defmodule ProcessingQueue.ValidationPipeline do
  @moduledoc """
  Orchestrates the validation phases for a torrent.

  Runs validators in sequence according to the FSM state flow:
  1. File count validation (⑦)
  2. Media validation (⑧)
  3. Path validation (⑨)

  Each validator can return:
  - `:ok` - Validation passed, continue to next
  - `{:skip, reason}` - Validation skipped (disabled by config), continue
  - `{:error, reason}` - Validation failed, stop pipeline

  ## Usage

      case ValidationPipeline.run(torrent) do
        {:ok, torrent} -> # All validations passed
        {:error, :file_count, reason} -> # File count validation failed
        {:error, :media, reason} -> # Media validation failed
        {:error, :path, reason} -> # Path validation failed
      end
  """

  require Logger

  alias ProcessingQueue.Torrent
  alias ProcessingQueue.Validators.{FileCountValidator, MediaValidator, PathValidator}

  @type validation_phase :: :file_count | :media | :path
  @type validation_result ::
          {:ok, Torrent.t()}
          | {:error, validation_phase(), term()}

  @doc """
  Runs the full validation pipeline.

  ## Parameters
    - `torrent` - Torrent struct to validate

  ## Returns
    - `{:ok, torrent}` - All validations passed
    - `{:error, phase, reason}` - Validation failed at specified phase
  """
  @spec run(Torrent.t()) :: validation_result()
  def run(%Torrent{hash: hash} = torrent) do
    Logger.info("[#{hash}] Starting validation pipeline")

    torrent
    |> run_file_count_validation()
    |> then_run(&run_media_validation/1)
    |> then_run(&run_path_validation/1)
    |> finalize_result(hash)
  end

  @doc """
  Runs only file count validation.
  """
  @spec run_file_count(Torrent.t()) :: :ok | {:skip, String.t()} | {:error, term()}
  def run_file_count(%Torrent{} = torrent) do
    FileCountValidator.validate(torrent)
  end

  @doc """
  Runs only media validation.
  """
  @spec run_media(Torrent.t()) :: :ok | {:skip, String.t()} | {:error, term()}
  def run_media(%Torrent{} = torrent) do
    MediaValidator.validate(torrent)
  end

  @doc """
  Runs only path validation.
  """
  @spec run_path(Torrent.t()) :: :ok | {:skip, String.t()} | {:error, term()}
  def run_path(%Torrent{} = torrent) do
    PathValidator.validate(torrent)
  end

  @doc """
  Runs path validation with retries.
  """
  @spec run_path_with_retry(Torrent.t(), keyword()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def run_path_with_retry(%Torrent{} = torrent, opts \\ []) do
    PathValidator.validate_with_retry(torrent, opts)
  end

  # Private functions

  defp run_file_count_validation(%Torrent{} = torrent) do
    case FileCountValidator.validate(torrent) do
      :ok ->
        {:ok, torrent}

      {:skip, reason} ->
        Logger.debug("[#{torrent.hash}] File count validation skipped: #{reason}")
        {:ok, torrent}

      {:error, reason} ->
        {:error, :file_count, reason}
    end
  end

  defp run_media_validation(%Torrent{} = torrent) do
    case MediaValidator.validate(torrent) do
      :ok ->
        {:ok, torrent}

      {:skip, reason} ->
        Logger.debug("[#{torrent.hash}] Media validation skipped: #{reason}")
        {:ok, torrent}

      {:error, reason} ->
        {:error, :media, reason}
    end
  end

  defp run_path_validation(%Torrent{} = torrent) do
    case PathValidator.validate_with_retry(torrent) do
      :ok ->
        {:ok, torrent}

      {:skip, reason} ->
        Logger.debug("[#{torrent.hash}] Path validation skipped: #{reason}")
        {:ok, torrent}

      {:error, reason} ->
        {:error, :path, reason}
    end
  end

  defp then_run({:ok, torrent}, next_fn) do
    next_fn.(torrent)
  end

  defp then_run({:error, _phase, _reason} = error, _next_fn) do
    error
  end

  defp finalize_result({:ok, torrent}, hash) do
    Logger.info("[#{hash}] Validation pipeline completed successfully")
    {:ok, torrent}
  end

  defp finalize_result({:error, phase, reason}, hash) do
    Logger.warning("[#{hash}] Validation pipeline failed at #{phase}: #{inspect(reason)}")
    {:error, phase, reason}
  end
end

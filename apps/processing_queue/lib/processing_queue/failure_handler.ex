defmodule ProcessingQueue.FailureHandler do
  @moduledoc """
  Wraps operations with error classification and proper handling.

  Provides a consistent way to execute operations that might fail,
  automatically classifying errors and determining the appropriate
  response (fail, raise, or warn).

  ## Error Categories

  - `:validation` - Triggers Sonarr re-search (aria2 code 24)
  - `:permanent` - No retry, cleanup RD immediately (aria2 code 1)
  - `:warning` - Shows as stalled, may recover (no error code)
  - `:application` - Raises exception, requires admin fix

  ## Usage

      # Execute an operation with automatic error handling
      case FailureHandler.execute(fn -> risky_operation() end) do
        {:ok, result} -> # Success
        {:error, failure} -> # Failure with classified error
      end

      # Build a failure struct directly
      failure = FailureHandler.build_failure(:validation, "File count mismatch", torrent)

      # Handle failure appropriately
      case FailureHandler.handle_failure(failure, torrent) do
        {:transition, :failed, updated_torrent} -> # Should transition to failed
        {:raise, error} -> # Should raise exception
      end
  """

  require Logger

  alias ProcessingQueue.{ErrorClassifier, RDPoller, ServarrSync, Torrent}

  @type failure_type :: :validation | :permanent | :warning | :application
  @type failure :: %{
          type: failure_type(),
          reason: term(),
          aria2_error_code: integer() | nil,
          cleanup_rd: boolean(),
          notify_servarr: boolean(),
          raise_exception: boolean(),
          timestamp: DateTime.t()
        }

  @doc """
  Builds a failure struct from an error.

  ## Parameters
    - `error` - Error to classify (string, atom, or any term)
    - `context` - Optional context for logging (default: %{})

  ## Returns
    - Failure struct with classification and handling instructions
  """
  @spec build_failure(term(), map()) :: failure()
  def build_failure(error, context \\ %{}) do
    type = ErrorClassifier.classify(error)

    %{
      type: type,
      reason: error,
      aria2_error_code: ErrorClassifier.aria2_error_code(type),
      cleanup_rd: ErrorClassifier.cleanup_rd?(type),
      notify_servarr: ErrorClassifier.notify_servarr?(type),
      raise_exception: ErrorClassifier.should_raise?(type),
      timestamp: DateTime.utc_now(),
      context: context
    }
  end

  @doc """
  Builds a failure with explicit type.

  Use when you know the error type and don't need classification.

  ## Parameters
    - `type` - Error type (:validation, :permanent, :warning, :application)
    - `reason` - Error reason/message
    - `context` - Optional context for logging

  ## Returns
    - Failure struct
  """
  @spec build_failure(failure_type(), term(), map()) :: failure()
  def build_failure(type, reason, context)
      when type in [:validation, :permanent, :warning, :application] do
    %{
      type: type,
      reason: reason,
      aria2_error_code: ErrorClassifier.aria2_error_code(type),
      cleanup_rd: ErrorClassifier.cleanup_rd?(type),
      notify_servarr: ErrorClassifier.notify_servarr?(type),
      raise_exception: ErrorClassifier.should_raise?(type),
      timestamp: DateTime.utc_now(),
      context: context
    }
  end

  @doc """
  Executes an operation with automatic error handling.

  If the operation fails, classifies the error and returns a failure struct.
  If the error type is `:application`, raises an exception.

  ## Parameters
    - `operation` - Function to execute
    - `context` - Optional context for logging

  ## Returns
    - `{:ok, result}` - Operation succeeded
    - `{:error, failure}` - Operation failed with classified error

  ## Raises
    - RuntimeError if error type is `:application`
  """
  @spec execute((-> {:ok, term()} | {:error, term()} | term()), map()) ::
          {:ok, term()} | {:error, failure()}
  def execute(operation, context \\ %{}) when is_function(operation, 0) do
    try do
      case operation.() do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          handle_error(reason, context)

        :ok ->
          {:ok, :ok}

        {:skip, reason} ->
          {:ok, {:skipped, reason}}

        other ->
          {:ok, other}
      end
    rescue
      e ->
        handle_error(Exception.message(e), Map.put(context, :exception, e))
    end
  end

  @doc """
  Handles a failure, performing appropriate actions.

  - Logs the failure
  - Notifies Servarr if configured
  - Cleans up RD if needed
  - Raises exception for application errors

  ## Parameters
    - `failure` - Failure struct
    - `torrent` - Torrent struct

  ## Returns
    - `{:transition, :failed, updated_torrent}` - Should transition to failed state
    - `{:raise, exception}` - Should raise exception

  ## Side Effects
    - May notify Servarr API
    - May delete RD torrent
  """
  @spec handle_failure(failure(), Torrent.t()) ::
          {:transition, :failed, Torrent.t()} | {:raise, Exception.t()}
  def handle_failure(%{raise_exception: true} = failure, %Torrent{hash: hash}) do
    Logger.error("[#{hash}] Application error - raising exception: #{inspect(failure.reason)}")
    {:raise, %RuntimeError{message: "Application error: #{inspect(failure.reason)}"}}
  end

  def handle_failure(failure, %Torrent{} = torrent) do
    hash = torrent.hash

    Logger.warning("[#{hash}] Handling #{failure.type} failure: #{inspect(failure.reason)}")

    # Notify Servarr if needed
    if failure.notify_servarr do
      notify_servarr(torrent, failure)
    end

    # Cleanup RD if needed
    if failure.cleanup_rd do
      cleanup_rd(torrent)
    end

    # Update torrent with failure info
    updated_torrent =
      torrent
      |> Map.put(:failure_type, failure.type)
      |> Map.put(:failure_reason, failure.reason)
      |> Map.put(:error_code, failure.aria2_error_code)

    {:transition, :failed, updated_torrent}
  end

  @doc """
  Convenience function to fail with a specific type.

  ## Parameters
    - `type` - Failure type
    - `reason` - Error reason
    - `torrent` - Torrent struct

  ## Returns
    - Same as `handle_failure/2`
  """
  @spec fail(failure_type(), term(), Torrent.t()) ::
          {:transition, :failed, Torrent.t()} | {:raise, Exception.t()}
  def fail(type, reason, torrent) do
    failure = build_failure(type, reason, %{hash: torrent.hash})
    handle_failure(failure, torrent)
  end

  @doc """
  Wraps a validation result in proper failure handling.

  Used for validation pipeline results.

  ## Parameters
    - `result` - Validation result (:ok, {:skip, reason}, {:error, reason})
    - `phase` - Validation phase name (for logging)
    - `torrent` - Torrent struct

  ## Returns
    - `:ok` - Validation passed
    - `{:transition, :failed, updated_torrent}` - Validation failed
  """
  @spec handle_validation_result(
          :ok | {:skip, term()} | {:error, term()},
          atom(),
          Torrent.t()
        ) :: :ok | {:transition, :failed, Torrent.t()} | {:raise, Exception.t()}
  def handle_validation_result(:ok, _phase, _torrent), do: :ok

  def handle_validation_result({:skip, reason}, phase, %Torrent{hash: hash}) do
    Logger.debug("[#{hash}] #{phase} validation skipped: #{reason}")
    :ok
  end

  def handle_validation_result({:error, reason}, phase, torrent) do
    # Validation errors are always :validation type
    failure =
      build_failure(:validation, "#{phase} validation failed: #{inspect(reason)}", %{
        hash: torrent.hash,
        phase: phase
      })

    handle_failure(failure, torrent)
  end

  @doc """
  Wraps a pipeline result in proper failure handling.

  Used for ValidationPipeline results.

  ## Parameters
    - `result` - Pipeline result
    - `torrent` - Torrent struct

  ## Returns
    - `{:ok, torrent}` - Pipeline passed
    - `{:transition, :failed, updated_torrent}` - Pipeline failed
  """
  @spec handle_pipeline_result(
          {:ok, Torrent.t()} | {:error, atom(), term()},
          Torrent.t()
        ) :: {:ok, Torrent.t()} | {:transition, :failed, Torrent.t()} | {:raise, Exception.t()}
  def handle_pipeline_result({:ok, torrent}, _original_torrent) do
    {:ok, torrent}
  end

  def handle_pipeline_result({:error, phase, reason}, torrent) do
    failure =
      build_failure(:validation, "#{phase} validation failed: #{inspect(reason)}", %{
        hash: torrent.hash,
        phase: phase
      })

    handle_failure(failure, torrent)
  end

  # Private functions

  defp handle_error(reason, context) do
    failure = build_failure(reason, context)

    if failure.raise_exception do
      raise RuntimeError, "Application error: #{inspect(reason)}"
    else
      {:error, failure}
    end
  end

  defp notify_servarr(%Torrent{servarr_url: nil}, _failure), do: :ok
  defp notify_servarr(%Torrent{servarr_api_key: nil}, _failure), do: :ok

  defp notify_servarr(%Torrent{} = torrent, failure) do
    if Aria2Debrid.Config.notify_servarr_on_failure?() do
      Logger.debug("[#{torrent.hash}] Notifying Servarr of failure")

      ServarrSync.notify_failure(
        torrent.servarr_url,
        torrent.servarr_api_key,
        torrent.hash,
        inspect(failure.reason)
      )
    else
      :ok
    end
  end

  defp cleanup_rd(%Torrent{rd_id: nil}), do: :ok

  defp cleanup_rd(%Torrent{rd_id: rd_id, hash: hash}) do
    case RDPoller.get_client() do
      nil ->
        Logger.warning("[#{hash}] No RD client available for cleanup")
        :ok

      client ->
        Logger.debug("[#{hash}] Cleaning up RD torrent: #{rd_id}")
        RDPoller.delete_torrent(client, rd_id)
    end
  end
end

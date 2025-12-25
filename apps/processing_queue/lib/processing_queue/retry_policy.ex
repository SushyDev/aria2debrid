defmodule ProcessingQueue.RetryPolicy do
  @moduledoc """
  Exponential backoff and retry policies for network operations.

  Provides consistent retry handling for:
  - Real-Debrid API calls
  - Servarr API calls
  - Path validation

  ## Usage

      # Run operation with retries
      RetryPolicy.with_retries(fn ->
        SomeApi.call()
      end, max_retries: 5, base_delay: 1000)

      # Calculate delay for a given attempt
      delay = RetryPolicy.exponential_delay(attempt, base_delay: 1000)
  """

  require Logger

  @default_base_delay 1_000
  @default_max_delay 60_000
  @default_max_retries 3

  @type retry_opts :: [
          max_retries: non_neg_integer(),
          base_delay: pos_integer(),
          max_delay: pos_integer(),
          retry_on: (term() -> boolean())
        ]

  @doc """
  Calculates exponential backoff delay for a given attempt.

  Uses formula: min(base_delay * 2^attempt, max_delay)

  ## Parameters
    - `attempt` - Attempt number (0-indexed)

  ## Options
    - `:base_delay` - Base delay in ms (default: 1000)
    - `:max_delay` - Maximum delay cap in ms (default: 60000)

  ## Returns
    - Delay in milliseconds

  ## Examples

      iex> RetryPolicy.exponential_delay(0)
      1000

      iex> RetryPolicy.exponential_delay(3)
      8000

      iex> RetryPolicy.exponential_delay(10, max_delay: 30_000)
      30000
  """
  @spec exponential_delay(non_neg_integer(), keyword()) :: pos_integer()
  def exponential_delay(attempt, opts \\ []) do
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)

    delay = base_delay * :math.pow(2, attempt) |> trunc()
    min(delay, max_delay)
  end

  @doc """
  Runs an operation with automatic retries.

  ## Parameters
    - `operation` - Zero-arity function to execute

  ## Options
    - `:max_retries` - Maximum retry attempts (default: 3)
    - `:base_delay` - Base delay in ms (default: 1000)
    - `:max_delay` - Maximum delay cap in ms (default: 60000)
    - `:retry_on` - Predicate function to determine if result should trigger retry
    - `:on_retry` - Callback called before each retry with attempt number

  ## Returns
    - Result of operation if successful
    - Last error/result if all retries exhausted

  ## Examples

      # Retry on any error
      RetryPolicy.with_retries(fn -> 
        Api.call()
      end)

      # Retry with custom predicate
      RetryPolicy.with_retries(
        fn -> Api.call() end,
        retry_on: fn
          {:error, :rate_limited} -> true
          _ -> false
        end
      )
  """
  @spec with_retries((-> term()), retry_opts()) :: term()
  def with_retries(operation, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    retry_on = Keyword.get(opts, :retry_on, &default_retry_predicate/1)
    on_retry = Keyword.get(opts, :on_retry, fn _ -> :ok end)

    do_with_retries(operation, 0, max_retries, retry_on, on_retry, opts)
  end

  defp do_with_retries(operation, attempt, max_retries, retry_on, on_retry, opts) do
    result = operation.()

    cond do
      not retry_on.(result) ->
        # Success or non-retryable result
        result

      attempt >= max_retries ->
        # Exhausted retries
        Logger.warning("Exhausted #{max_retries} retries")
        result

      true ->
        # Retry
        delay = exponential_delay(attempt, opts)
        on_retry.(attempt + 1)
        Logger.debug("Retry #{attempt + 1}/#{max_retries} after #{delay}ms")
        Process.sleep(delay)
        do_with_retries(operation, attempt + 1, max_retries, retry_on, on_retry, opts)
    end
  end

  @doc """
  Default predicate for determining if a result should trigger a retry.

  Retries on:
  - `{:error, _}` tuples
  - `:error` atoms

  Does not retry on:
  - `{:ok, _}` tuples
  - `:ok` atoms
  - Any other value
  """
  @spec default_retry_predicate(term()) :: boolean()
  def default_retry_predicate({:error, _}), do: true
  def default_retry_predicate(:error), do: true
  def default_retry_predicate(_), do: false

  @doc """
  Creates a retry predicate that matches specific error patterns.

  ## Examples

      predicate = RetryPolicy.retry_on_errors([:timeout, :rate_limited])
      predicate.({:error, :timeout})  # => true
      predicate.({:error, :not_found})  # => false
  """
  @spec retry_on_errors([atom()]) :: (term() -> boolean())
  def retry_on_errors(error_types) when is_list(error_types) do
    fn
      {:error, error} when is_atom(error) -> error in error_types
      {:error, {error, _}} when is_atom(error) -> error in error_types
      _ -> false
    end
  end

  @doc """
  Waits for a condition with polling.

  ## Parameters
    - `condition` - Zero-arity function that returns true when condition is met

  ## Options
    - `:poll_interval` - Time between polls in ms (default: 1000)
    - `:timeout` - Maximum wait time in ms (default: 30000)

  ## Returns
    - `:ok` - Condition met
    - `{:error, :timeout}` - Timeout reached

  ## Examples

      RetryPolicy.wait_until(fn ->
        File.exists?("/some/path")
      end, timeout: 60_000)
  """
  @spec wait_until((-> boolean()), keyword()) :: :ok | {:error, :timeout}
  def wait_until(condition, opts \\ []) do
    poll_interval = Keyword.get(opts, :poll_interval, 1_000)
    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(condition, deadline, poll_interval)
  end

  defp do_wait_until(condition, deadline, poll_interval) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      if condition.() do
        :ok
      else
        Process.sleep(poll_interval)
        do_wait_until(condition, deadline, poll_interval)
      end
    end
  end

  @doc """
  Runs operation and returns result with timing info.

  ## Returns
    - `{result, elapsed_ms}`
  """
  @spec timed((-> term())) :: {term(), non_neg_integer()}
  def timed(operation) do
    start = System.monotonic_time(:millisecond)
    result = operation.()
    elapsed = System.monotonic_time(:millisecond) - start
    {result, elapsed}
  end
end

defmodule MediaValidator do
  @moduledoc """
  Media file validation using FFprobe.

  Validates that media files are valid video files with required streams
  and filters out sample files.
  """

  alias MediaValidator.FFprobe

  @type validation_result :: :ok | {:error, String.t()}
  @type file_info :: %{
          path: String.t(),
          size: non_neg_integer(),
          duration: float() | nil,
          has_video: boolean(),
          has_audio: boolean()
        }

  @doc """
  Validates a media file.

  Returns `:ok` if the file passes all validation checks, or `{:error, reason}`
  if validation fails.

  ## Validation checks:
  - File exists and is readable
  - File is not a sample (based on name and duration)
  - File has video stream (if required)
  - File has audio stream (if required)
  """
  @spec validate(String.t(), keyword()) :: validation_result()
  def validate(path, opts \\ []) do
    enabled = Keyword.get(opts, :enabled, Aria2Debrid.Config.media_validation_enabled?())

    if enabled do
      do_validate(path, opts)
    else
      :ok
    end
  end

  @doc """
  Validates a media file via URL (e.g., Real-Debrid streaming link).

  This is used when files aren't available locally but can be validated
  via HTTP streaming. Skips file existence checks.

  ## Validation checks:
  - File has video stream (if required)
  - File has audio stream (if required)
  - File is not a sample by duration
  """
  @spec validate_url(String.t(), keyword()) :: validation_result()
  def validate_url(url, opts \\ []) do
    enabled = Keyword.get(opts, :enabled, Aria2Debrid.Config.media_validation_enabled?())

    if enabled do
      do_validate_url(url, opts)
    else
      :ok
    end
  end

  @doc """
  Validates multiple files, returning the first error encountered.
  """
  @spec validate_all([String.t()], keyword()) :: validation_result()
  def validate_all(paths, opts \\ []) do
    Enum.reduce_while(paths, :ok, fn path, _acc ->
      case validate(path, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Gets detailed information about a media file.
  """
  @spec get_file_info(String.t()) :: {:ok, file_info()} | {:error, term()}
  def get_file_info(path) do
    with {:ok, probe_data} <- FFprobe.probe(path) do
      {:ok,
       %{
         path: path,
         size: get_file_size(path),
         duration: FFprobe.get_duration(probe_data),
         has_video: FFprobe.has_video_stream?(probe_data),
         has_audio: FFprobe.has_audio_stream?(probe_data)
       }}
    end
  end

  @doc """
  Filters a list of files to only include valid streamable video files.
  """
  @spec filter_video_files([String.t()]) :: [String.t()]
  def filter_video_files(paths) do
    extensions = Aria2Debrid.Config.streamable_extensions()

    Enum.filter(paths, fn path ->
      ext = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
      ext in extensions
    end)
  end

  @doc """
  Checks if a file appears to be a sample based on its name.
  """
  @spec is_sample_by_name?(String.t()) :: boolean()
  def is_sample_by_name?(path) do
    filename = Path.basename(path) |> String.downcase()

    String.contains?(filename, "sample") or
      String.starts_with?(filename, "sample") or
      Regex.match?(~r/[\.\-_]sample[\.\-_]/, filename)
  end

  defp do_validate(path, opts) do
    require_video =
      Keyword.get(opts, :require_video_stream, Aria2Debrid.Config.require_video_stream?())

    require_audio =
      Keyword.get(opts, :require_audio_stream, Aria2Debrid.Config.require_audio_stream?())

    reject_samples =
      Keyword.get(opts, :reject_sample_files, Aria2Debrid.Config.reject_sample_files?())

    sample_min_runtime =
      Keyword.get(opts, :sample_min_runtime, Aria2Debrid.Config.sample_min_runtime())

    with :ok <- check_file_exists(path),
         :ok <- check_not_sample_by_name(path, reject_samples),
         {:ok, probe_data} <- FFprobe.probe(path),
         :ok <- check_video_stream(probe_data, require_video),
         :ok <- check_audio_stream(probe_data, require_audio),
         :ok <- check_not_sample_by_duration(probe_data, reject_samples, sample_min_runtime) do
      :ok
    end
  end

  defp do_validate_url(url, opts) do
    require_video =
      Keyword.get(opts, :require_video_stream, Aria2Debrid.Config.require_video_stream?())

    require_audio =
      Keyword.get(opts, :require_audio_stream, Aria2Debrid.Config.require_audio_stream?())

    reject_samples =
      Keyword.get(opts, :reject_sample_files, Aria2Debrid.Config.reject_sample_files?())

    sample_min_runtime =
      Keyword.get(opts, :sample_min_runtime, Aria2Debrid.Config.sample_min_runtime())

    filename = url |> URI.parse() |> Map.get(:path, "") |> Path.basename()

    with :ok <- check_not_sample_by_name(filename, reject_samples),
         {:ok, probe_data} <- FFprobe.probe(url),
         :ok <- check_video_stream(probe_data, require_video),
         :ok <- check_audio_stream(probe_data, require_audio),
         :ok <- check_not_sample_by_duration(probe_data, reject_samples, sample_min_runtime) do
      :ok
    end
  end

  defp check_file_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, "File does not exist: #{path}"}
    end
  end

  defp check_not_sample_by_name(_path, false), do: :ok

  defp check_not_sample_by_name(path, true) do
    if is_sample_by_name?(path) do
      {:error, "File appears to be a sample: #{Path.basename(path)}"}
    else
      :ok
    end
  end

  defp check_video_stream(_probe_data, false), do: :ok

  defp check_video_stream(probe_data, true) do
    if FFprobe.has_video_stream?(probe_data) do
      :ok
    else
      {:error, "File has no video stream"}
    end
  end

  defp check_audio_stream(_probe_data, false), do: :ok

  defp check_audio_stream(probe_data, true) do
    if FFprobe.has_audio_stream?(probe_data) do
      :ok
    else
      {:error, "File has no audio stream"}
    end
  end

  defp check_not_sample_by_duration(_probe_data, false, _min_runtime), do: :ok

  defp check_not_sample_by_duration(probe_data, true, min_runtime) do
    case FFprobe.get_duration(probe_data) do
      nil ->
        :ok

      duration when duration < min_runtime ->
        {:error, "File duration too short (#{round(duration)}s), likely a sample"}

      _ ->
        :ok
    end
  end

  defp get_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end

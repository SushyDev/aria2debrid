defmodule MediaValidator.FFprobe do
  @moduledoc """
  FFprobe wrapper for extracting media file information.
  """

  require Logger

  @type probe_data :: map()

  @doc """
  Probes a media file and returns parsed JSON data.
  Works with both local paths and URLs.
  """
  @spec probe(String.t()) :: {:ok, probe_data()} | {:error, term()}
  def probe(path_or_url) do
    timeout = Aria2Debrid.Config.ffprobe_timeout()

    args = [
      "-v",
      "quiet",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      path_or_url
    ]

    args =
      if String.starts_with?(path_or_url, "http") do
        [
          "-timeout",
          to_string(timeout * 1000),
          "-protocol_whitelist",
          "file,http,https,tcp,tls"
          | args
        ]
      else
        args
      end

    task = Task.async(fn -> System.cmd("ffprobe", args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout + 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_parse_error, reason}}
        end

      {:ok, {output, exit_code}} ->
        Logger.warning("FFprobe failed for #{truncate_path(path_or_url)}: exit #{exit_code}")
        {:error, {:ffprobe_failed, exit_code, output}}

      nil ->
        Logger.warning("FFprobe timeout for #{truncate_path(path_or_url)}")
        {:error, :timeout}
    end
  rescue
    e in ErlangError ->
      {:error, {:ffprobe_not_found, e}}
  end

  defp truncate_path(path) do
    if String.starts_with?(path, "http") do
      uri = URI.parse(path)
      "#{uri.scheme}://#{uri.host}/..."
    else
      path
    end
  end

  @doc """
  Checks if the probed data contains a video stream.
  """
  @spec has_video_stream?(probe_data()) :: boolean()
  def has_video_stream?(data) do
    streams = Map.get(data, "streams", [])
    Enum.any?(streams, fn stream -> stream["codec_type"] == "video" end)
  end

  @doc """
  Checks if the probed data contains an audio stream.
  """
  @spec has_audio_stream?(probe_data()) :: boolean()
  def has_audio_stream?(data) do
    streams = Map.get(data, "streams", [])
    Enum.any?(streams, fn stream -> stream["codec_type"] == "audio" end)
  end

  @doc """
  Gets the duration in seconds from probed data.
  """
  @spec get_duration(probe_data()) :: float() | nil
  def get_duration(data) do
    cond do
      duration = get_in(data, ["format", "duration"]) ->
        parse_duration(duration)

      true ->
        streams = Map.get(data, "streams", [])

        video_stream = Enum.find(streams, fn s -> s["codec_type"] == "video" end)

        if video_stream do
          parse_duration(video_stream["duration"])
        else
          nil
        end
    end
  end

  @doc """
  Gets the video codec from probed data.
  """
  @spec get_video_codec(probe_data()) :: String.t() | nil
  def get_video_codec(data) do
    streams = Map.get(data, "streams", [])
    video_stream = Enum.find(streams, fn s -> s["codec_type"] == "video" end)
    video_stream && video_stream["codec_name"]
  end

  @doc """
  Gets the audio codec from probed data.
  """
  @spec get_audio_codec(probe_data()) :: String.t() | nil
  def get_audio_codec(data) do
    streams = Map.get(data, "streams", [])
    audio_stream = Enum.find(streams, fn s -> s["codec_type"] == "audio" end)
    audio_stream && audio_stream["codec_name"]
  end

  @doc """
  Gets video resolution as {width, height}.
  """
  @spec get_resolution(probe_data()) :: {non_neg_integer(), non_neg_integer()} | nil
  def get_resolution(data) do
    streams = Map.get(data, "streams", [])
    video_stream = Enum.find(streams, fn s -> s["codec_type"] == "video" end)

    if video_stream do
      width = video_stream["width"]
      height = video_stream["height"]

      if width && height do
        {width, height}
      else
        nil
      end
    else
      nil
    end
  end

  defp parse_duration(nil), do: nil
  defp parse_duration(duration) when is_float(duration), do: duration
  defp parse_duration(duration) when is_integer(duration), do: duration * 1.0

  defp parse_duration(duration) when is_binary(duration) do
    case Float.parse(duration) do
      {value, _} -> value
      :error -> nil
    end
  end
end

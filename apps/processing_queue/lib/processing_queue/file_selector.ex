defmodule ProcessingQueue.FileSelector do
  @moduledoc """
  Filters and selects files from Real-Debrid torrents.

  ## File Selection Rules

  Based on configuration, selects:
  - Video files: mkv, mp4, avi, m4v, mov, wmv, webm (configurable)
  - Subtitle files: srt, sub, idx, ass, ssa, smi, vtt (configurable)
  - Metadata files: nfo, jpg, jpeg, png, tbn (configurable)

  All matching files are selected regardless of size.

  ## Usage

      files = [
        %{"id" => 1, "path" => "/Movie/movie.mkv", "bytes" => 1_500_000_000},
        %{"id" => 2, "path" => "/Movie/sample.mkv", "bytes" => 50_000_000},
        %{"id" => 3, "path" => "/Movie/subs.srt", "bytes" => 50_000}
      ]

      FileSelector.select(files)
      # => [1, 2, 3]  # selects all video and subtitle files
  """

  @doc """
  Selects file IDs to download based on extension and size requirements.

  Returns a list of file IDs that should be selected for download.

  ## Parameters
    - `files` - List of file maps with "id", "path", and "bytes" keys

  ## Returns
    - List of integer file IDs

  ## Examples

      iex> files = [%{"id" => 1, "path" => "movie.mkv", "bytes" => 1_000_000_000}]
      iex> FileSelector.select(files)
      [1]
  """
  @spec select([map()]) :: [integer()]
  def select(files) when is_list(files) do
    if Aria2Debrid.Config.select_all?() do
      Enum.map(files, & &1["id"])
    else
      files
      |> Enum.filter(&selectable?/1)
      |> Enum.map(& &1["id"])
    end
  end

  @doc """
  Filters files to only those that are selected and are video files.

  Returns a list of file maps matching the criteria.

  ## Parameters
    - `files` - List of file maps

  ## Returns
    - Filtered list of file maps
  """
  @spec filter_selected_video_files([map()]) :: [map()]
  def filter_selected_video_files(files) when is_list(files) do
    files
    |> Enum.filter(fn file -> file["selected"] == 1 end)
    |> Enum.filter(&video_file?/1)
  end

  @doc """
  Counts the number of selected video files.

  ## Parameters
    - `files` - List of file maps

  ## Returns
    - Count of selected video files
  """
  @spec count_selected_video_files([map()]) :: non_neg_integer()
  def count_selected_video_files(files) when is_list(files) do
    files
    |> filter_selected_video_files()
    |> length()
  end

  @doc """
  Checks if a file is a video file based on its extension.

  ## Parameters
    - `file` - File map with "path" key

  ## Returns
    - `true` if the file is a video file, `false` otherwise
  """
  @spec video_file?(map()) :: boolean()
  def video_file?(file) when is_map(file) do
    path = file["path"] || file[:path]
    ext = get_extension(path)
    ext in video_extensions()
  end

  @doc """
  Checks if a file is marked as selected.

  Works with both string and atom keys (from RD API responses).

  ## Parameters
    - `file` - File map with "selected" key

  ## Returns
    - `true` if selected (value is 1 or true), `false` otherwise
  """
  @spec selected?(map()) :: boolean()
  def selected?(file) when is_map(file) do
    selected = file["selected"] || file[:selected]
    selected == 1 or selected == true
  end

  @doc """
  Checks if a file is a video file based on its extension (struct format).

  Works with Real-Debrid TorrentInfo file structs.
  """
  @spec video_file_struct?(struct()) :: boolean()
  def video_file_struct?(%{path: path}) when is_binary(path) do
    ext = get_extension(path)
    ext in video_extensions()
  end

  def video_file_struct?(_), do: false

  @doc """
  Checks if a file should be selected for download.

  Video, subtitle, and metadata files are all selected if they match the extension list.
  """
  @spec selectable?(map()) :: boolean()
  def selectable?(file) when is_map(file) do
    ext = get_extension(file["path"])

    cond do
      # Video files
      ext in video_extensions() ->
        true

      # Additional files (subtitles, metadata)
      ext in additional_extensions() ->
        true

      # Other files are not selected
      true ->
        false
    end
  end

  # Private functions

  defp get_extension(nil), do: ""

  defp get_extension(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
  end

  defp video_extensions do
    Aria2Debrid.Config.streamable_extensions()
  end

  defp additional_extensions do
    Aria2Debrid.Config.additional_selectable_files()
  end
end

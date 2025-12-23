defmodule ServarrClient.QueueItem do
  @moduledoc """
  Represents an item in the Sonarr/Radarr download queue.
  """

  @type t :: %__MODULE__{
          id: integer(),
          download_id: String.t() | nil,
          title: String.t(),
          status: String.t(),
          tracked_download_status: String.t() | nil,
          tracked_download_state: String.t() | nil,
          status_messages: [map()],
          error_message: String.t() | nil,
          size: integer(),
          sizeleft: integer(),
          output_path: String.t() | nil,
          # Sonarr specific
          series_id: integer() | nil,
          episode_id: integer() | nil,
          season_number: integer() | nil,
          # Radarr specific
          movie_id: integer() | nil
        }

  defstruct [
    :id,
    :download_id,
    :title,
    :status,
    :tracked_download_status,
    :tracked_download_state,
    :status_messages,
    :error_message,
    :size,
    :sizeleft,
    :output_path,
    :series_id,
    :episode_id,
    :season_number,
    :movie_id
  ]

  @doc """
  Parses a queue item from the API response.
  """
  @spec from_api(map()) :: t()
  def from_api(data) do
    %__MODULE__{
      id: data["id"],
      download_id: data["downloadId"],
      title: data["title"],
      status: data["status"],
      tracked_download_status: data["trackedDownloadStatus"],
      tracked_download_state: data["trackedDownloadState"],
      status_messages: data["statusMessages"] || [],
      error_message: data["errorMessage"],
      size: data["size"] || 0,
      sizeleft: data["sizeleft"] || 0,
      output_path: data["outputPath"],
      # Sonarr fields
      series_id: data["seriesId"],
      episode_id: data["episodeId"],
      season_number: data["seasonNumber"],
      # Radarr fields
      movie_id: data["movieId"]
    }
  end

  @doc """
  Returns the expected episode/movie count for this queue item.

  For series, this returns 1 (single episode) unless it's a season pack.
  For movies, this always returns 1.
  """
  @spec expected_file_count(t()) :: pos_integer()
  def expected_file_count(%__MODULE__{movie_id: movie_id}) when not is_nil(movie_id), do: 1
  def expected_file_count(%__MODULE__{episode_id: episode_id}) when not is_nil(episode_id), do: 1
  def expected_file_count(_), do: 1

  @doc """
  Returns true if the download is in a warning state.
  """
  @spec has_warning?(t()) :: boolean()
  def has_warning?(%__MODULE__{tracked_download_status: "warning"}), do: true
  def has_warning?(_), do: false

  @doc """
  Returns true if the download is in an error state.
  """
  @spec has_error?(t()) :: boolean()
  def has_error?(%__MODULE__{tracked_download_status: "error"}), do: true
  def has_error?(_), do: false

  @doc """
  Returns the download progress as a percentage (0.0 - 100.0).
  """
  @spec progress(t()) :: float()
  def progress(%__MODULE__{size: 0}), do: 0.0

  def progress(%__MODULE__{size: size, sizeleft: sizeleft}) do
    (size - sizeleft) / size * 100.0
  end
end

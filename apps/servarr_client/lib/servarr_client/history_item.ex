defmodule ServarrClient.HistoryItem do
  @moduledoc """
  Represents an item in the Sonarr/Radarr history.
  """

  @type event_type ::
          :grabbed | :download_folder_imported | :download_failed | :download_ignored | :unknown

  @type t :: %__MODULE__{
          id: integer(),
          download_id: String.t() | nil,
          source_title: String.t(),
          event_type: event_type(),
          date: DateTime.t() | nil,
          quality: map(),
          data: map(),
          # Sonarr specific
          series_id: integer() | nil,
          episode_id: integer() | nil,
          # Radarr specific
          movie_id: integer() | nil
        }

  defstruct [
    :id,
    :download_id,
    :source_title,
    :event_type,
    :date,
    :quality,
    :data,
    :series_id,
    :episode_id,
    :movie_id
  ]

  @doc """
  Parses a history item from the API response.
  """
  @spec from_api(map()) :: t()
  def from_api(data) do
    %__MODULE__{
      id: data["id"],
      download_id: data["downloadId"],
      source_title: data["sourceTitle"],
      event_type: parse_event_type(data["eventType"]),
      date: parse_date(data["date"]),
      quality: data["quality"] || %{},
      data: data["data"] || %{},
      # Sonarr fields
      series_id: data["seriesId"],
      episode_id: data["episodeId"],
      # Radarr fields
      movie_id: data["movieId"]
    }
  end

  @doc """
  Returns true if this was a successful import.
  """
  @spec imported?(t()) :: boolean()
  def imported?(%__MODULE__{event_type: :download_folder_imported}), do: true
  def imported?(_), do: false

  @doc """
  Returns true if this was a failed download.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{event_type: :download_failed}), do: true
  def failed?(_), do: false

  @doc """
  Returns true if this was a grab event (download started).
  """
  @spec grabbed?(t()) :: boolean()
  def grabbed?(%__MODULE__{event_type: :grabbed}), do: true
  def grabbed?(_), do: false

  # Private functions

  defp parse_event_type("grabbed"), do: :grabbed
  defp parse_event_type("downloadFolderImported"), do: :download_folder_imported
  defp parse_event_type("downloadFailed"), do: :download_failed
  defp parse_event_type("downloadIgnored"), do: :download_ignored
  defp parse_event_type(_), do: :unknown

  defp parse_date(nil), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end
end

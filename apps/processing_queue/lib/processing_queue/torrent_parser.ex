defmodule ProcessingQueue.TorrentParser do
  @moduledoc """
  Parses torrent files to extract metadata, particularly the infohash.

  The infohash is the SHA1 hash of the bencoded info dictionary,
  which uniquely identifies a torrent.
  """

  @doc """
  Extracts the infohash from a torrent file's binary data.

  ## Parameters
    - torrent_data: Binary content of the .torrent file

  ## Returns
    - `{:ok, hash}` - The 40-character hex infohash (lowercase)
    - `{:error, reason}` - If parsing fails

  ## Examples

      iex> File.read!("example.torrent") |> TorrentParser.extract_infohash()
      {:ok, "abcdef1234567890abcdef1234567890abcdef12"}
  """
  @spec extract_infohash(binary()) :: {:ok, String.t()} | {:error, term()}
  def extract_infohash(torrent_data) when is_binary(torrent_data) do
    with {:ok, decoded} <- safe_decode(torrent_data),
         {:ok, info_dict} <- get_info_dict(decoded),
         {:ok, info_encoded} <- safe_encode(info_dict),
         hash <- compute_sha1(info_encoded) do
      {:ok, hash}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Failed to parse torrent file"}
    end
  rescue
    e ->
      {:error, "Exception parsing torrent: #{Exception.message(e)}"}
  end

  defp safe_decode(data) do
    try do
      Bento.decode(data)
    rescue
      e -> {:error, "Bento decode failed: #{Exception.message(e)}"}
    end
  end

  defp safe_encode(data) do
    try do
      Bento.encode(data)
    rescue
      e -> {:error, "Bento encode failed: #{Exception.message(e)}"}
    end
  end

  defp get_info_dict(%{"info" => info}), do: {:ok, info}
  defp get_info_dict(_), do: {:error, "Missing 'info' dictionary in torrent"}

  defp compute_sha1(data) do
    :crypto.hash(:sha, data)
    |> Base.encode16(case: :lower)
  end
end

defmodule MediaValidatorTest do
  use ExUnit.Case, async: true

  describe "is_sample_by_name?/1" do
    test "detects sample in filename" do
      assert MediaValidator.is_sample_by_name?("movie.sample.mkv")
      assert MediaValidator.is_sample_by_name?("Sample-movie.mkv")
      assert MediaValidator.is_sample_by_name?("movie-sample-720p.mkv")
      assert MediaValidator.is_sample_by_name?("sample.mkv")
    end

    test "does not flag regular files" do
      refute MediaValidator.is_sample_by_name?("movie.mkv")
      refute MediaValidator.is_sample_by_name?("The.Movie.2024.1080p.mkv")
      refute MediaValidator.is_sample_by_name?("episode.s01e01.mkv")
    end
  end

  describe "filter_video_files/1" do
    test "filters to only video extensions" do
      files = [
        "/path/to/movie.mkv",
        "/path/to/movie.mp4",
        "/path/to/movie.srt",
        "/path/to/movie.nfo",
        "/path/to/movie.avi"
      ]

      result = MediaValidator.filter_video_files(files)

      assert "/path/to/movie.mkv" in result
      assert "/path/to/movie.mp4" in result
      assert "/path/to/movie.avi" in result
      refute "/path/to/movie.srt" in result
      refute "/path/to/movie.nfo" in result
    end
  end
end

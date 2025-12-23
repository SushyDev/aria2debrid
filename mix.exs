defmodule Aria2Debrid.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    []
  end

  defp aliases do
    [
      test: ["test --trace"]
    ]
  end

  defp releases do
    [
      aria2debrid: [
        applications: [
          config: :permanent,
          servarr_client: :permanent,
          media_validator: :permanent,
          processing_queue: :permanent,
          aria2_api: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ]
    ]
  end
end

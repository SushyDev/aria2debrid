defmodule ProcessingQueue.MixProject do
  use Mix.Project

  def project do
    [
      app: :processing_queue,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ProcessingQueue.Application, []}
    ]
  end

  defp deps do
    [
      {:real_debrid_ex, github: "sushydev/real_debrid_ex"},
      {:config, in_umbrella: true},
      {:servarr_client, in_umbrella: true},
      {:media_validator, in_umbrella: true},
      {:bento, "~> 1.0"}
    ]
  end
end

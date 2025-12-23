defmodule Aria2Api.MixProject do
  use Mix.Project

  def project do
    [
      app: :aria2_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Aria2Api.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:sweet_xml, "~> 0.7"},
      {:processing_queue, in_umbrella: true},
      {:config, in_umbrella: true}
    ]
  end
end

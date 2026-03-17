defmodule TestCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_tui,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        test_tui: [
          applications: [
            runtime_tools: :permanent
          ],
          steps: [:assemble, :tar]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :kernel, :stdlib, :elixir],
      mod: {TestCli.Application, []}
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../.."}
    ]
  end
end

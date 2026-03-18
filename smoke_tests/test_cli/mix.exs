defmodule TestCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_cli,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        test_cli: [
          cookie: "test_cookie",
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestCli.Application, []}
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../.."}
    ]
  end
end

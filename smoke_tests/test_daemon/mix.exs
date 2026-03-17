defmodule TestDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_daemon,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestDaemon.Application, []}
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../.."}
    ]
  end
end

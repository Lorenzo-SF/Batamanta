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
            runtime_tools: :permanent,
            kernel: :permanent,
            stdlib: :permanent
          ],
          steps: [:assemble],
          cookie: "test_cookie",
          vm_args: Path.join(__DIR__, "vm.args")
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestCli.Application, []},
      registered: []
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../.."}
    ]
  end
end

defmodule TestTui.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_tui,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      batamanta: [
        execution_mode: :tui,
        compression: 1
      ],
      releases: [
        test_tui: [
          include_executables_for: [:unix],
          applications: [test_tui: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [mod: {TestTui, []}]
  end

  defp deps do
    [{:batamanta, path: "../../", runtime: false}]
  end
end

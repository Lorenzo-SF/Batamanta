defmodule TestDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_daemon,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      batamanta: [
        execution_mode: :daemon,
        compression: 1
      ],
      releases: [
        test_daemon: [
          include_executables_for: [:unix],
          applications: [test_daemon: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [mod: {TestDaemon, []}]
  end

  defp deps do
    [{:batamanta, path: "../../", runtime: false}]
  end
end

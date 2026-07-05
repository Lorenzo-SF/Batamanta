defmodule TestReleaseCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_release_cli,
      version: "0.1.0",

      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Configuración de Batamanta
      # execution_mode: :cli porque TestReleaseCli tiene un módulo
      # TestReleaseCli.CLI.main/1 que recibe los argumentos de línea de comandos.
      batamanta: [
        execution_mode: :cli,
        compression: 1
      ],
      releases: [
        test_release_cli: [
          include_executables_for: [:unix],
          applications: [test_release_cli: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestReleaseCli, []}
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../../", runtime: false}
    ]
  end
end

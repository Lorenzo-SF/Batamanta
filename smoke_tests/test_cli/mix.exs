defmodule TestCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_cli,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Configuración de Batamanta
      # Si no se especifica erts_target, se usa :auto por defecto
      batamanta: [
        execution_mode: :cli,
        compression: 1
        # erts_target: :auto  # Por defecto si no se especifica
      ],
      releases: [
        test_cli: [
          include_executables_for: [:unix],
          applications: [test_cli: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestCli, []}
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../../", runtime: false}
    ]
  end
end

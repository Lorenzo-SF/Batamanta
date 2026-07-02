defmodule TestCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_cli,
      version: "0.1.0",
#      elixir: "~> 1.19",   # Pinned by .tool-versions (elixir 1.15.8-otp-26)

      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Configuración de Batamanta
      # execution_mode: :daemon porque TestCli no tiene un módulo
      # TestCli.CLI.main/1 — lee los argumentos directamente desde
      # :init.get_plain_arguments() en Application.start/2.
      batamanta: [
        execution_mode: :daemon,
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

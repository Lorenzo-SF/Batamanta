defmodule TestEscript.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_escript,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Configuración de escript
      escript: escript(),
      # Configuración de Batamanta para escript
      batamanta: [
        format: :escript,
        execution_mode: :cli,
        compression: 1
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../../", runtime: false}
    ]
  end

  defp escript do
    [main_module: TestEscript.CLI]
  end
end

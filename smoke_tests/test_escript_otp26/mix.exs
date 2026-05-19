defmodule TestEscriptOtp26.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_escript_otp26,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      batamanta: [
        format: :escript,
        otp_version: "26.0",
        execution_mode: :cli,
        compression: 1
      ],
      releases: [
        test_escript_otp26: [
          include_executables_for: [:unix],
          applications: [test_escript_otp26: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [mod: {TestEscriptOtp26, []}, extra_applications: [:logger]]
  end

  defp deps do
    [{:batamanta, path: "../../", runtime: false}]
  end
end

defmodule TestReleaseOtp27.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_release_otp27,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      batamanta: [
        otp_version: "27.0",
        execution_mode: :cli,
        compression: 1
      ],
      releases: [
        test_release_otp27: [
          include_executables_for: [:unix],
          applications: [test_release_otp27: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [mod: {TestReleaseOtp27, []}, extra_applications: [:logger]]
  end

  defp deps do
    [{:batamanta, path: "../../", runtime: false}]
  end
end

defmodule TestReleaseNif.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_release_nif,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      batamanta: [
        # Deliberately pin to the system OTP version (26.x) to keep
        # this smoke test fast and self-contained — it does not need
        # to exercise the ERTS download path, only the include_erts:
        # false layout where the batamanta wrapper used to crash with
        # `load_failed` on kernel/stdlib.
        otp_version: "26.0",
        execution_mode: :cli,
        compression: 1
      ],
      releases: [
        test_release_nif: [
          include_executables_for: [:unix],
          # The case this smoke test guards: release ships WITHOUT
          # the ERTS. batamanta must supply the ERTS as a flattened
          # directory and the wrapper must point ROOTDIR at it.
          include_erts: false,
          applications: [test_release_nif: :permanent],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [mod: {TestReleaseNif, []}, extra_applications: [:logger]]
  end

  defp deps do
    [{:batamanta, path: "../../", runtime: false}]
  end
end

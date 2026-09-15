defmodule TestBeamDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_beam_daemon,
      version: "0.1.0",

      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The new `daemon:` block enables the BEAM-keeps-alive feature.
      # We keep `execution_mode: :cli` because the daemon dispatches to
      # the user app's `*CLI.main(args)` — same as legacy CLI mode.
      batamanta: [
        execution_mode: :cli,
        compression: 1,
        daemon: [
          enabled: true,
          # Default TTL is 30s — enough for the smoke test's 15-call
          # loop to all hit the warm BEAM.
          default_ms: 30_000,
          user_app: :test_beam_daemon,
          request_timeout_ms: 5_000
        ]
      ],
      releases: [
        test_beam_daemon: [
          include_executables_for: [:unix],
          applications: [
            test_beam_daemon: :permanent,
            batamanta_daemon: :permanent
          ],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TestBeamDaemon, []}
    ]
  end

  defp deps do
    [
      {:batamanta, path: "../../", runtime: false}
    ]
  end
end

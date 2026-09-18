defmodule Batamanta.MixProject do
  use Mix.Project

  @version "3.0.0"
  @source_url "https://github.com/Lorenzo-SF/Batamanta"
  @elixir_vsn "~> 1.15"

  def project do
    [
      app: :batamanta,
      version: @version,
      elixir: @elixir_vsn,
      # NB: we intentionally do NOT set `elixirc_paths/1` here. Doing so
      # would make Mix treat `test/support/*.exs` as regular app source
      # during `MIX_ENV=test`, which races with ExUnit's own discovery
      # of those files. The race surfaces as `MatchError {:error, :enoent}`
      # in `Kernel.ParallelCompiler.require_file/2` on Elixir 1.18+ —
      # whichever test file happens to be loaded first alphabetically
      # (banner_test, runner_test, target_test, ...) reports the crash.
      # The support files are still loaded by `test_helper.exs` via
      # `Code.require_file/1` (see test/test_helper.exs); only ExUnit
      # discovery is excluded (see `test_ignore_filters` below).
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      test_coverage: [
        tool: ExCoveralls,
        summary: [
          threshold: 100
        ]
      ],
      # Helpers used by ExUnit (loaded by test_helper.exs via
      # Code.require_file) must NOT be treated as test modules; otherwise
      # the parallel compiler will try to load them as such and fail with
      # MatchError {:error, :enoent} on Elixir 1.18+ when support files
      # are first discovered by the file-system glob.
      test_ignore_filters: [
        ~r/test\/support\/.*\.exs/,
        ~r/test\/test_httpc\.exs/
      ]
    ]
  end

  defp description do
    "Encapsulates Elixir releases alongside their ERTS into self-contained executable binaries. Downloads ERTS from the official mirror (Lorenzo-SF/Batamanta---ERTS-repository) with fallback to system ERTS if unavailable."
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/batamantaman.png",
      extras: ["README.md", "README_ES.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Batamanta, Batamanta.Application, Batamanta.Runner, Batamanta.Runner.Native],
        Packaging: [
          Batamanta.Packager,
          Batamanta.EscriptPackager,
          Batamanta.EscriptBuilder,
          Batamanta.Compression,
          Batamanta.Compression.Backend,
          Batamanta.Compression.Gzip,
          Batamanta.Compression.None,
          Batamanta.Compression.Zstd,
          Batamanta.Release.Step,
          Batamanta.RunScript,
          Batamanta.RustTemplate
        ],
        ERTS: [Batamanta.ERTS.Fetcher, Batamanta.ERTS.LibcDetector, Batamanta.Target],
        Daemon: [Batamanta.Daemon, Batamanta.DaemonConfig],
        Display: [Batamanta.Banner, Batamanta.Logger],
        Utilities: [Batamanta.EnvCleaner, Batamanta.Validator],
        "Mix Tasks": [Mix.Tasks.Batamanta, Mix.Tasks.Batamanta.Clean, Mix.Tasks.Rust.Test]
      ]
    ]
  end

  defp package do
    [
      name: "batamanta",
      files: ~w(lib mix.exs README* LICENSE* CHANGELOG*
                priv/assets priv/erts_repository priv/plts priv/daemon
                priv/rust_template/Cargo.* priv/rust_template/src
                priv/rust_template/build.rs
                assets/batamantaman.png),
      maintainers: ["Lorenzo-SF"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Batamanta.Application, []}
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:jason, "~> 1.0"},
      {:xref_runner, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      check: ["format", "credo --strict", "dialyzer"],
      "rust.test": ["cmd cargo test --manifest-path priv/rust_template/Cargo.toml"]
    ]
  end
end

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
      # NOTE: `priv/plts` (local dialyzer artifacts) and
      # `priv/erts_repository` (offline MANIFEST fallback, owned by the
      # ERTS-repo CI and not tracked here) are intentionally NOT shipped:
      # `mix hex.build` fails on missing entries, and the Fetcher already
      # handles their absence (disk cache, then empty manifest).
      files: ~w(lib mix.exs README* LICENSE* CHANGELOG*
                priv/assets priv/daemon
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

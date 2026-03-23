defmodule Batamanta.MixProject do
  use Mix.Project

  @version "1.2.1"
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
      ]
    ]
  end

  defp description do
    "Encapsulates Elixir releases alongside their ERTS into self-contained executable binaries. Downloads ERTS from Hex.pm with fallback to system ERTS if unavailable."
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/batamantaman.png",
      extras: ["README.md", "README_ES.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      name: "batamanta",
      files: ["lib", "priv", "mix.exs", "README*", "LICENSE*", "CHANGELOG*", "assets"],
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
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["format", "credo --strict", "dialyzer"],
      "rust.test": ["cmd cargo test --manifest-path priv/rust_template/Cargo.toml"],
      "test.all": ["test", "rust.test"]
    ]
  end
end

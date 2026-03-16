defmodule Batamanta do
  @moduledoc """
  **Batamanta** is a packaging utility that creates 100% self-contained
  executable binaries from Elixir releases.

  It packages your Elixir application along with the complete Erlang Runtime
  System (ERTS) into a single static binary, eliminating any dependency on
  Erlang or Elixir being installed on the target machine.

  ## Features

  - **Self-contained binaries**: No Erlang/Elixir installation required on target
  - **Cross-compilation**: Build for Linux (MUSL), macOS, and Windows from any platform
  - **Compression**: Uses Zstandard for optimal size/performance balance
  - **Multiple execution modes**: CLI, TUI, and Daemon support

  ## Quick Start

  Add Batamanta to your dependencies and configure it in `mix.exs`:

      def project do
        [
          app: :my_app,
          version: "0.1.0",
          deps: [{:batamanta, path: "...", runtime: false}],
          batamanta: [
            target_os: "linux",
            target_arch: "x86_64",
            execution_mode: :cli,
            compression: 3
          ]
        ]
      end

  Then build your executable:

      $ mix batamanta

  ## Configuration Options

  - `target_os` - Operating system: `"linux"`, `"macos"`, `"windows"`
  - `target_arch` - Architecture: `"x86_64"`, `"aarch64"`
  - `execution_mode` - Execution type: `:cli`, `:tui`, `:daemon`
  - `compression` - Zstd compression level (1-19, default: 3)

  Override configuration via CLI:

      $ mix batamanta --target-os linux --target-arch aarch64 --compression 5

  ## Version

      iex> Batamanta.version()
      "1.0.1"

  """

  @version "1.0.1"

  @doc """
  Returns the current version of Batamanta.
  """
  @spec version() :: String.t()
  def version, do: @version
end

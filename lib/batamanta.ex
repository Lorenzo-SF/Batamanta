defmodule Batamanta do
  @moduledoc """
  **Batamanta** is a packaging utility that creates 100% self-contained
  executable binaries from Elixir releases.

  It packages your Elixir application along with the complete Erlang Runtime
  System (ERTS) into a single static binary, eliminating any dependency on
  Erlang or Elixir being installed on the target machine.

  ## Features

  - **Self-contained binaries**: No Erlang/Elixir installation required on target
  - **Cross-compilation**: Build for Linux (glibc/musl), macOS, and Windows from any platform
  - **Compression**: Uses Zstandard for optimal size/performance balance
  - **Multiple execution modes**: CLI, TUI, and Daemon support
  - **Escript format**: Lightweight bundling for projects using `mix escript.build`
  - **Release format**: Full OTP release with supervisor tree
  - **Automatic Cleanup**: Wipes temporary build artifacts while preserving the ERTS cache

  ## Configuration

  Add Batamanta to your dependencies and configure it in `mix.exs`:

      def project do
        [
          app: :my_app,
          version: "0.1.0",
          deps: [{:batamanta, "~> 1.0", runtime: false}],
          batamanta: [
            format: :escript,
            erts_target: :auto,
            execution_mode: :cli,
            compression: 3
          ]
        ]
      end

  Then build your executable:

      $ mix batamanta

  See `mix help batamanta` for all available options.
  """

  @version "1.5.2"

  @doc """
  Returns the current version of Batamanta.
  """
  @spec version() :: String.t()
  def version, do: @version
end

defmodule Batamanta.RunScript do
  @moduledoc """
  Generates the `<app>.run` shell script embedded in the release tarball.

  The `.run` script is the entry point for the final binary (after the Rust
  wrapper extracts the payload). It sets up the environment (PATH, BINDIR,
  neutralizes asdf/mise) and execs the appropriate target:

    - **escript format**: execs `release/bin/<app>` directly.
      The escript shebang (`#!/usr/bin/env escript`) finds the bundled
      `escript` via PATH, which finds `erl` via PATH, which finds
      `erlexec` via BINDIR. No ESCRIPT_EMULATOR needed on OTP ≤ 26.

    - **release format**: execs `release/bin/<app>` with the right subcommand:
      * `cli`   → `eval 'Module.CLI.main()' -- "$@"`
      * `daemon` → `daemon "$@"`
      * `tui`   → `start "$@"`

  This script is ~1KB and is GENERATED at build time by batamanta, not at
  runtime by the Rust wrapper. Changing env vars does NOT require recompiling
  the Rust dispenser.
  """

  @doc """
  Generates the `.run` script content as a string.

  ## Parameters

    - `app_name` - Application name (e.g., `"delfos"`, `"test_escript"`)
    - `exec_mode` - Execution mode: `:cli`, `:daemon`, or `:tui`
    - `format` - Output format: `:escript` or `:release`
    - `erts_version` - ERTS version string (e.g., `"14.2"`)
    - `opts` - Optional overrides:
      * `:cli_module` - Custom CLI module (default: `Macro.camelize(app_name) <> ".CLI"`)

  ## Returns

    String containing the run script (with trailing newline).
  """
  @spec generate(String.t(), atom(), atom(), String.t(), keyword()) :: String.t()
  def generate(app_name, exec_mode, format, erts_version, opts \\ []) do
    cli_module = Keyword.get(opts, :cli_module, derive_cli_module(app_name))
    exec_mode_str = Atom.to_string(exec_mode)
    format_str = Atom.to_string(format)

    fragments = %{
      erts_dir: "erts-#{erts_version}",
      cli_module: cli_module,
      exec_mode: exec_mode_str,
      format: format_str,
      app_name: app_name
    }

    script = ~S"""
    #!/bin/sh
    # GENERADO POR BATAMANTA — NO EDITAR
    set -e

    SELF=$(readlink "$0" || true)
    [ -z "$SELF" ] && SELF="$0"
    RELEASE_ROOT="$(CDPATH='' cd "$(dirname "$SELF")/.." && pwd -P)"
    ERTS_DIR="$RELEASE_ROOT/__ERTS_DIR__"
    ERTS_BIN="$ERTS_DIR/bin"

    export PATH="$ERTS_BIN:$PATH"
    export BINDIR="$ERTS_BIN"
    export RELEASE_ROOT
    # ERL_ROOTDIR: only set for escript format. The erl script is patched
    # to use BINDIR="$ROOTDIR/bin" (instead of $ROOTDIR/erts-X.Y/bin), so
    # ROOTDIR must point to the ERTS root. For release format, erl script
    # keeps original BINDIR="$ROOTDIR/erts-X.Y/bin" and dyn_erl resolves
    # ROOTDIR correctly; setting ERL_ROOTDIR would double-nest the ERTS dir.

    # Neutralizar version managers (asdf, mise, kerl)
    export ERL_FLAGS="" ERL_AFLAGS="" ERL_ZFLAGS=""

    # ─── exec ──────────────────────────────────────────────────────────────────
    case "__FORMAT__" in
      escript)
        # erl script patched to use BINDIR="$ROOTDIR/bin"; need ROOTDIR=ERTS dir
        export ERL_ROOTDIR="$ERTS_DIR"
        exec "$RELEASE_ROOT/bin/__APP_NAME__" "$@"
        ;;
      release)
        case "__MODE__" in
          cli)
            exec "$RELEASE_ROOT/bin/__APP_NAME__" eval '__CLI_MODULE__.main(System.argv())' "$@"
            ;;
          daemon)
            exec "$RELEASE_ROOT/bin/__APP_NAME__" daemon "$@"
            ;;
          tui)
            exec "$RELEASE_ROOT/bin/__APP_NAME__" start "$@"
            ;;
        esac
        ;;
    esac
    """

    script
    |> String.replace("__ERTS_DIR__", fragments.erts_dir)
    |> String.replace("__CLI_MODULE__", fragments.cli_module)
    |> String.replace("__MODE__", fragments.exec_mode)
    |> String.replace("__FORMAT__", fragments.format)
    |> String.replace("__APP_NAME__", fragments.app_name)
  end

  @doc """
  Derives the CLI module name from the application name.

  ## Examples

      iex> Batamanta.RunScript.derive_cli_module("delfos")
      "Delfos.CLI"

      iex> Batamanta.RunScript.derive_cli_module("test_escript")
      "TestEscript.CLI"

  """
  @spec derive_cli_module(String.t()) :: String.t()
  def derive_cli_module(app_name) do
    app_name
    |> Macro.camelize()
    |> Kernel.<>(".CLI")
  end
end

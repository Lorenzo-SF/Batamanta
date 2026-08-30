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
    
    # BATAMANTA_USER_ARGS (Windows only): the Rust wrapper serializes the
    # user's CLI args into this env var (each arg single-quoted and joined
    # with spaces) and we re-parse them via eval. This is the workaround
    # for multi-word args being split somewhere in the
    # `bash -c` -> `source` -> `exec` chain on Windows. POSIX path uses
    # execvp directly and never sets this var, so the if block is a
    # no-op and $@ keeps whatever the user passed on the command line.
    if [ -n "$BATAMANTA_USER_ARGS" ]; then
      eval "set -- $BATAMANTA_USER_ARGS"
    fi
    
    # Windows Rust wrapper invokes us as:
    #   bash -c "<wrapper-script>" -- <user-arg-1> <user-arg-2> ...
    # The `--` ends up as $1 in this sourced context, shifting the user's
    # real args by one (so alaja sees "--" as its first arg and reports
    # "unknown command '--'"). Strip the `--` if present. This is a
    # no-op on POSIX (where the .run script is exec'd directly and $1
    # is the user's first arg).
    [ "$1" = "--" ] && shift
    
    # Determine our own path. Three sources, in order of preference:
    #   1. BATAMANTA_RUN_SCRIPT — set by the Rust wrapper on Windows
    #      (which `source`s this script, so $0 is "bash" and the
    #      readlink trick below can't work)
    #   2. The classic readlink trick: this works on POSIX when the
    #      script is `exec`'d or invoked as a normal shell script
    #   3. Fallback to $0 (might be "bash" if sourced, but the rest of
    #      the script still does its best with whatever path it can get)
    if [ -n "$BATAMANTA_RUN_SCRIPT" ]; then
      SELF="$BATAMANTA_RUN_SCRIPT"
    else
      SELF=$(readlink "$0" 2>/dev/null || true)
      [ -z "$SELF" ] && SELF="$0"
    fi
    RELEASE_ROOT="$(CDPATH='' cd "$(dirname "$SELF")/.." && pwd -P)"
    ERTS_DIR="$RELEASE_ROOT/__ERTS_DIR__"
    ERTS_BIN="$ERTS_DIR/bin"
    
    # ERL_BINDIR may be set externally (e.g. by the Windows Rust wrapper
    # which auto-locates a working system Erlang). If so, honour it: the
    # bundled `bin/erl.exe` in the payload is the NSIS installer shim and
    # crashes (0xC0000005) when invoked outside the installer's context
    # on Windows. On POSIX the bundled erl is real, so when ERL_BINDIR
    # is NOT set we fall back to the payload's own bin/.
    if [ -n "$ERL_BINDIR" ]; then
      ERTS_BIN="$ERL_BINDIR"
    fi
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
    # Normalize to LF. The source file may contain CRLF (e.g. after a
    # Windows checkout), and heredoc sigils keep the \r. A CRLF shebang
    # (`#!/bin/sh\r`) breaks execvp on POSIX with "No such file or
    # directory" — the kernel looks for an interpreter literally named
    # `/bin/sh\r`.
    |> String.replace("\r\n", "\n")
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

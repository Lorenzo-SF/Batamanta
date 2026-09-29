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

    # ERL_BINDIR may be set externally as a manual escape hatch. If so,
    # honour it. Otherwise the payload's own bin/ is used, so the release
    # boots EXCLUSIVELY from the bundled ERTS (system Erlang is never
    # consulted by the wrapper).
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

    # Special arg set by the Rust wrapper when it wants to bootstrap the
    # BEAM daemon (bind the Unix-domain socket) without running any CLI
    # command yet. The wrapper will then send its own request over the
    # socket and exit, leaving the BEAM alive for the next invocation.
    #
    # NB: this block MUST stay below the RELEASE_ROOT/ERTS_DIR derivation
    # above. It used to live right after the BATAMANTA_USER_ARGS eval,
    # before SELF was resolved, so `$RELEASE_ROOT` expanded to the empty
    # string and the exec became `/bin/<app>` — which never exists, hence:
    #   exec: /bin/test_beam_daemon: not found
    if [ "$1" = "batamanta_daemon_bootstrap" ]; then
      shift
      # Run the daemon app and park. The user app is started by the
      # release's start.boot as usual (sibling to the daemon); only the
      # CLI dispatch is routed over the socket.
      # Syntax notes, since both of these bit us and the failure mode is
      # a bare SyntaxError with no hint about the real cause:
      #
      #   1. `receive do ... end` — the `do` form. `receive ... end`
      #      without it parses as a bare `receive` with clauses and
      #      blows up with "unexpected reserved word: end".
      #   2. `spawn(fn -> ... end)` — the receive needs an enclosing
      #      function body. `bin/<app> eval` runs the string via
      #      Code.eval_string/3, which has no body, so a top-level
      #      receive is a syntax error regardless of the do-form.
      #      Wrapping in spawn gives it a body AND is the behaviour we
      #      want: the spawned process parks on the receive while the
      #      caller returns, leaving the BEAM up to serve the socket.
      #   3. `;` not `,` between the ensure_all_started call and the
      #      receive. A comma there is a syntax error:
      #      "syntax error before: ','". Within a `fn` body the
      #      statement separator is a semicolon; a comma only separates
      #      arguments in a call.
      #
      # 4. `Application.ensure_all_started/1` must be fully qualified.
      #    The unqualified `ensure_all_started/1` does NOT exist — it is
      #    not a Kernel function — and compiling it gives
      #      error: undefined function ensure_all_started/1
      #             (there is no such import)
      #    The original `application:ensure_all_started(...)` instead
      #    failed with "keyword argument must be followed by space after:
      #    application:". Qualifying with `Application.` sidesteps that
      #    ambiguity entirely.
      #
      # The daemon's own server process (batamanta_daemon_sup) binds the
      # listening socket during application start, so ensure_all_started
      # is enough to make the daemon reachable — the receive just keeps
      # the VM from shutting down after the caller returns.
      exec "$RELEASE_ROOT/bin/__APP_NAME__" eval 'spawn(fn -> Application.ensure_all_started(batamanta_daemon); receive do _ -> :ok end end)' "$@"
    fi

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

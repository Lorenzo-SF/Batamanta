defmodule Batamanta.RunScriptBootstrapTest do
  @moduledoc """
  The daemon bootstrap branch of the generated `.run` script.

  Regression cover for the bug that made every daemon-enabled invocation
  cost 30 seconds. Four separate defects had to line up for the daemon to
  start, and each one on its own produced the same symptom — no socket,
  so the wrapper sat out its full 30s bind timeout and fell back to a
  cold start:

    1. The eval was not valid Elixir: `batamanta_daemon` without a colon
       is an undefined variable.
    2. The daemon app was never staged into the release, and is not on
       the release code path even once it is.
    3. The generated `.app` had no `{mod, ...}`, so
       `ensure_all_started/1` reported success while starting nothing.
    4. The eval parked a *spawned* process, but `--eval` halts the VM
       when the expression returns, so the socket was created and then
       unlinked during shutdown.

  These tests parse the string the way `bin/<app> eval` does, because
  that is precisely the step that kept failing.
  """
  use ExUnit.Case, async: true

  defp bootstrap_eval(script) do
    case Regex.run(~r/eval '(.*?)' "\$@"/s, script) do
      [_, eval] -> eval
      nil -> flunk("no bootstrap eval found in the generated run script")
    end
  end

  defp run_script(opts \\ []) do
    app = Keyword.get(opts, :app, "alaja")
    mode = Keyword.get(opts, :mode, :cli)
    format = Keyword.get(opts, :format, :release)
    Batamanta.RunScript.generate(app, mode, format, "16.4")
  end

  describe "bootstrap eval" do
    test "is valid Elixir — this is the exact failure that cost 30s per call" do
      eval = bootstrap_eval(run_script())

      assert {:ok, _ast} = Code.string_to_quoted(eval),
             """
             the generated bootstrap eval does not parse; `bin/<app> eval` compiles \
             it, so this is what killed the daemon before it could bind a socket:

             #{eval}
             """
    end

    test "uses the :batamanta_daemon atom, not a bare variable" do
      eval = bootstrap_eval(run_script())

      # A bare `batamanta_daemon` in argument position parses as a
      # VARIABLE. `Code.string_to_quoted/1` with default options does not
      # warn on that, so assert on the source.
      assert eval =~ "Application.ensure_all_started(:batamanta_daemon)"
      refute eval =~ ~r/ensure_all_started\(\s*batamanta_daemon\s*\)/
    end

    test "puts the daemon ebin on the code path before starting it" do
      eval = bootstrap_eval(run_script())

      # `mix release` only bundles apps from the consumer's declared
      # application graph, so the daemon's ebin is not on the path even
      # once the packager stages it. Without add_pathz, ensure_all_started
      # answers {:error, {:batamanta_daemon, "no such file or directory"}}.
      assert eval =~ ":code.add_pathz"
    end

    test "adds the code path before asking the application to start" do
      eval = bootstrap_eval(run_script())
      add = :binary.match(eval, ":code.add_pathz") |> elem(0)
      start = :binary.match(eval, "ensure_all_started") |> elem(0)
      assert add < start, "the ebin must be on the code path before ensure_all_started"
    end

    test "parks THIS process — `bin/<app> eval` halts the VM on return" do
      eval = bootstrap_eval(run_script())

      # `--eval` halts the emulator once the expression returns, so a
      # `spawn(fn -> ... end)` dies with the VM: the socket gets created
      # and unlinked during shutdown, and the wrapper polling for that
      # file never sees it. The eval itself must block.
      refute eval =~ "spawn",
             "a spawned park does not survive `--eval` halting the VM"

      assert eval =~ "Process.sleep(:infinity)",
             "the eval must block forever, not return"
    end

    test "starts the daemon before parking" do
      eval = bootstrap_eval(run_script())
      start = :binary.match(eval, "ensure_all_started") |> elem(0)
      park = :binary.match(eval, "Process.sleep(:infinity)") |> elem(0)
      assert start < park
    end
  end

  describe "the ebin path comes from the shell" do
    test "the eval reads it from the environment" do
      eval = bootstrap_eval(run_script())
      assert eval =~ ~s|System.get_env("BATAMANTA_DAEMON_EBIN")|
    end

    test "the eval does not glob for it" do
      # A glob inside the eval needs a binding or a `case`, and erl_eval
      # raises on both here (see the erl_eval constraints below). The
      # shell knows $RELEASE_ROOT and the daemon version at generation
      # time, so it computes the directory and exports it.
      eval = bootstrap_eval(run_script())
      refute eval =~ ":filelib.wildcard"
    end

    test "the shell builds it from RELEASE_ROOT and exports it" do
      script = run_script()
      assert script =~ ~s|BATAMANTA_DAEMON_EBIN="$RELEASE_ROOT/lib/batamanta_daemon-|
      assert script =~ "export BATAMANTA_DAEMON_EBIN"
    end

    test "the daemon version placeholder is substituted" do
      script = run_script()
      refute script =~ "__DAEMON_VSN__"
      assert script =~ "batamanta_daemon-#{Batamanta.Daemon.version()}/ebin"
    end

    test "a custom daemon version is honoured" do
      script =
        Batamanta.RunScript.generate("alaja", :cli, :release, "16.4", daemon_version: "9.9.9")

      assert script =~ "batamanta_daemon-9.9.9/ebin"
    end
  end

  describe "erl_eval constraints" do
    # `bin/<app> eval` reaches erl_eval with a pre-seeded binding (the
    # `--` separator leaves a trailing empty argument). In that mode
    # erl_eval evaluates top-level assignments and case/fn patterns as
    # MATCHES against the existing binding, so they raise:
    #
    #     ** (MatchError) no match of right hand side value: "..."
    #     ** (CaseClauseError) no case clause matching: [...]
    #     ** (FunctionClauseError) ...:"-inside-an-interpreted-fun-"
    #
    # Plain function calls and `;`-separated statements are fine.
    test "no top-level assignment" do
      eval = bootstrap_eval(run_script())
      refute eval =~ ~r/^\s*[A-Za-z_][A-Za-z0-9_]*\s*=[^=~]/
    end

    test "no case expressions" do
      eval = bootstrap_eval(run_script())
      refute eval =~ ~r/\bcase\b.*\bdo\b/
    end

    test "no anonymous functions" do
      eval = bootstrap_eval(run_script())
      refute eval =~ "fn ", "erl_eval raises FunctionClauseError on interpreted funs here"
    end

    test "stays on one line so no shell quoting can break it" do
      eval = bootstrap_eval(run_script())
      refute eval =~ "\n", "a multi-line eval is fragile inside a single-quoted shell argument"
    end

    test "contains no single quote, which would terminate the shell argument" do
      eval = bootstrap_eval(run_script())
      refute eval =~ "'"
    end
  end

  describe "generated for every format/mode" do
    for {mode, format} <- [
          {:cli, :release},
          {:tui, :release},
          {:daemon, :release},
          {:cli, :escript}
        ] do
      test "generates a parseable bootstrap for #{format} + #{mode}" do
        script = run_script(mode: unquote(mode), format: unquote(format))
        eval = bootstrap_eval(script)
        assert {:ok, _} = Code.string_to_quoted(eval)
        assert eval =~ "Process.sleep(:infinity)"
      end
    end
  end

  describe "non-daemon entry points are untouched" do
    test "cli mode dispatches to the derived CLI module" do
      script = run_script()

      assert script =~
               ~s|exec "$RELEASE_ROOT/bin/alaja" eval 'Alaja.CLI.main(System.argv())' "$@"|
    end

    test "cli module is derived from the app name" do
      script = run_script(app: "acho")
      assert script =~ "Acho.CLI.main(System.argv())"
    end

    test "tui mode uses the release's start subcommand" do
      script = run_script(mode: :tui)
      assert script =~ ~s|exec "$RELEASE_ROOT/bin/alaja" start "$@"|
    end

    test "daemon mode uses the release's daemon subcommand" do
      script = run_script(mode: :daemon)
      assert script =~ ~s|exec "$RELEASE_ROOT/bin/alaja" daemon "$@"|
    end

    test "escript format execs the binary directly" do
      script = run_script(format: :escript)
      assert script =~ ~s|exec "$RELEASE_ROOT/bin/alaja" "$@"|
    end
  end
end

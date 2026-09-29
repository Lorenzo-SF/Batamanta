defmodule Batamanta.DaemonSourceContractTest do
  @moduledoc """
  Invariants of the Erlang daemon sources that unit tests cannot reach.

  The daemon is plain Erlang compiled by `erlc` at package time and has
  no eunit harness, so each of these is a defect that shipped and had to
  be found by hand, at 30 seconds a shell invocation. They are cheap to
  assert on the source and expensive to rediscover.

  Every entry below corresponds to a real failure.
  """
  use ExUnit.Case, async: true

  @src Path.join([:code.priv_dir(:batamanta), "daemon", "src"])

  defp read(file), do: File.read!(Path.join(@src, file))

  defp controller, do: read("batamanta_daemon_app_controller.erl")
  defp server, do: read("batamanta_daemon_server.erl")
  defp app, do: read("batamanta_daemon_app.erl")
  defp protocol, do: read("batamanta_daemon_protocol.erl")

  describe "Elixir module resolution" do
    test "prefixes candidates with the Elixir. namespace" do
      # `list_to_atom("Alaja.CLI")` is NOT the module behind the name
      # "Alaja.CLI"; that is `Elixir.Alaja.CLI'. The un-prefixed atom
      # matches no file, so ensure_loaded answered {:error, :nofile} and
      # every request came back "no CLI module found" — for every Elixir
      # project, which is all of them.
      src = controller()
      assert src =~ ~s|list_to_atom("Elixir." ++ Name)|
      assert src =~ "name_variants"
    end

    test "tries the bare atom too, so a hand-written Erlang module still resolves" do
      assert controller() =~ "[list_to_atom(Name)]"
    end

    test "does not already-prefixed names stay single-candidate" do
      assert controller() =~ ~s|lists:prefix("Elixir.", Name)|
    end
  end

  describe "module loading" do
    test "loads the module before asking whether main/1 is exported" do
      # function_exported/3 answers false for a module that is merely on
      # the code path. The daemon boots with start_clean, so the user
      # app's modules are never loaded until something asks.
      src = controller()
      load = :binary.match(src, "code:ensure_loaded(M)") |> elem(0)
      exported = :binary.match(src, "function_exported(M, main, 1)") |> elem(0)
      assert load < exported
    end

    test "does not pattern-match the return shape of code:ensure_loaded/1" do
      # OTP 27 returns {module, Mod}; OTP 28 returns [module: Mod].
      # Matching the tuple silently matched nothing on OTP 28.
      refute controller() =~ ~r/case\s+code:ensure_loaded\(/
      assert controller() =~ "_ = code:ensure_loaded(M)"
    end
  end

  describe "request keys" do
    test "reads request fields as binaries, because json:decode/1 keys are binaries" do
      src = controller()
      # Matching/fetching atom keys raised FunctionClauseError on every
      # request (exit code 1 for a perfectly good CLI).
      refute src =~ ~r/maps:get\(cwd,/
      refute src =~ ~r/#\{args :=/
      assert src =~ ~s|req_field(Req, <<"args">>, [])|
      assert src =~ ~s|req_field(Req, <<"cwd">>, undefined)|
    end
  end

  describe "environment values" do
    test "normalises the baked identity and build hash to binaries" do
      # os:getenv/1,2 returns a charlist. Compared against JSON-decoded
      # binaries, an is_binary/1 guard matched nothing and the server
      # died on the first request.
      src = app()
      assert src =~ "to_binary(os:getenv(?IDENTITY_ENV"
      assert src =~ "to_binary(os:getenv(?BUILD_HASH_ENV"
    end

    test "the server compares identities in a shape-agnostic way" do
      src = server()
      assert src =~ "identity_matches(_Req, <<>>)"
      assert src =~ "req_identity(Req)"
    end
  end

  describe "the accept loop exists" do
    test "something actually calls gen_tcp:accept/1" do
      # The server bound the socket and wrote the pid file but never
      # accepted: the wrapper connected, wrote a frame nobody read, and
      # blocked. The daemon looked perfectly healthy while being inert.
      assert server() =~ "gen_tcp:accept(ListenSock)"
      assert server() =~ "accept_loop("
    end

    test "is primed from init/1" do
      assert server() =~ "spawn(fun() -> accept_loop(ListenSock, Server) end)"
    end

    test "a connection reads one frame and writes one reply" do
      src = server()
      assert src =~ "handle_connection(Sock, Server)"
      assert src =~ "read_frame(Sock)"
      assert src =~ "write_frame(Sock, Reply)"
    end

    test "refuses an oversized length prefix before allocating for it" do
      assert server() =~ "?MAX_FRAME_BYTES"
    end
  end

  describe "framing" do
    test "encode/1 uses iolist_size, since json:encode/1 returns an iolist" do
      # byte_size/1 on the iolist raised badarg on EVERY reply, so the
      # connection process died before a byte reached the client.
      src = protocol()
      assert src =~ "iolist_to_binary(json_encode(Term))"
      refute src =~ ~r/^\s*Json = json_encode\(Term\),\s*Len = byte_size/m
    end

    test "round-trips a reply through decode" do
      assert protocol() =~ "-spec encode(term()) -> {ok, binary()}"
    end
  end

  describe "response shape" do
    test "keeps the error a binary so JSON encodes it as a string" do
      # binary_to_list/1 made json:encode/1 emit an array of byte values,
      # and the wrapper's as_str() fell back to "unknown" — every
      # rejection reason silently swallowed.
      assert server() =~ "error => Msg"
      refute server() =~ "error => binary_to_list("
    end
  end

  describe "output capture" do
    test "waits for the io_servers to flush before the ETS table dies" do
      # Sending `stop` and moving on let the flush land after run/3's
      # `after` block deleted the table: "the table identifier does not
      # refer to an existing ETS table", exit code 1, every request.
      src = controller()
      assert src =~ "{io_server_stopped, Ref}"
      assert src =~ "after ?IO_FLUSH_TIMEOUT_MS"
    end

    test "survives a late flush anyway" do
      assert controller() =~ "error:badarg -> ok"
    end
  end

  describe "exit code mapping" do
    test "treats nil and ok as success" do
      # Alaja's generated main/1 ends in an `if` with no `else`, so it
      # returns nil on every successful run. Mapping that to 1 made a
      # healthy daemon report failure to the shell.
      src = controller()
      assert src =~ "exit_code(nil) -> 0;"
      assert src =~ "exit_code(ok) -> 0;"
      assert src =~ "exit_code(true) -> 0;"
    end

    test "still maps 0 to 0 and errors to 1" do
      src = controller()
      assert src =~ "exit_code(0) -> 0;"
      assert src =~ "exit_code({error, _}) -> 1;"
    end
  end

  describe "per-request identity" do
    test "takes the CLI module from the request, not the daemon's env" do
      # A warm daemon keeps the environment it booted with, so reading
      # os:getenv/1 alone would dispatch every request to whatever module
      # THIS VM was built for.
      src = controller()
      assert src =~ ~s|req_field(Req, <<"cli_module">>, <<>>)|
      assert src =~ "cli_module_candidates(binary_to_list(M))"
    end

    test "takes the user app from the request too" do
      assert controller() =~ ~s|req_field(Req, <<"user_app">>, <<>>)|
    end

    test "falls back to the daemon env only for older wrappers" do
      assert controller() =~ "env_cli_module()"
    end
  end

  describe "the subcommand is not mined for a module name" do
    test "no is_module_name heuristic" do
      # `alaja success "x"` used to be read as a request for the module
      # `Success`, filling the candidate list with Success.CLI &
      # friends. The first argument is a subcommand, full stop.
      refute controller() =~ "is_module_name"
    end
  end
end

-module(batamanta_daemon_app_controller).

%% @doc Per-request runner for the Batamanta BEAM daemon.
%%
%% Captures the user app's stdout/stderr by swapping the worker's
%% `group_leader/0` to a custom `io_server` process (an `io` protocol
%% implementation in pure Erlang) that buffers all writes. This is the
%% same approach used by `ExUnit.CaptureIO` and Elixir's
%% `StringIO` under the hood.
%%
%% Protocol (from RFC §"Manejo de stdout/stderr"):
%%   1. Open an empty ETS table for the request.
%%   2. Spawn an io_server process and use it as the worker's group leader.
%%   3. The worker runs the user CLI under `spawn_monitor`.
%%   4. After the worker exits (or hits the request timeout), we read the
%%      ETS table to assemble the captured stdout/stderr.
%%   5. Return `{ExitCode, Stdout, Stderr}` to the caller.

-export([run/3]).

-type request() :: #{
    args => [binary()],
    env  => #{binary() => binary()},
    cwd  => binary() | undefined,
    stdin_b64 => binary() | undefined
}.

-type result() ::
    {ok, ExitCode :: non_neg_integer(), Stdout :: binary(), Stderr :: binary()}
  | {error, Reason :: term()}.

-export_type([request/0, result/0]).

-define(DEFAULT_TIMEOUT_MS, 60_000).

%% How long to wait for an io_server to acknowledge its final flush.
-define(IO_FLUSH_TIMEOUT_MS, 5_000).

%% ============================================================================
%% Public API
%% ============================================================================

-spec run(request(), atom() | undefined, pos_integer()) -> result().
run(Req, UserApp, TimeoutMs) ->
    Table = ets:new(capture, [public, ordered_set]),
    try
        {WorkerPid, MonRef, Servers} = start_worker(Req, UserApp, Table),
        wait_for_worker(WorkerPid, MonRef, Servers, Table, TimeoutMs)
    after
        %% Silently delete the ETS table if it still exists; otherwise
        %% ignore the badarg. Using try/catch instead of the deprecated
        %% `catch` form so the daemon compiles cleanly under OTP 27+ with
        %% -Werror.
        clear_stderr_sink(),
        try ets:delete(Table)
        catch _:_ -> ok
        end
    end.

%% ============================================================================
%% Worker lifecycle
%% ============================================================================

start_worker(Req, UserApp, Table) ->
    StdoutServer = start_io_server(Table, stdout),
    StderrServer = start_io_server(Table, stderr),
    %% Publish the stderr sink while the request runs.
    %
    %% `IO.puts(:stderr, msg)` resolves `:stderr` through the NODE's boot
    %% argument, so in a warm daemon it lands on the daemon's own stderr
    %% — invisible to the client, which never sees it. Anything the user
    %% app writes explicitly to `:stderr` (an error path, a warning) would
    %% simply disappear. Handing it the pid of this request's stderr
    %% io_server makes those writes land in the response instead.
    %
    %% Requests are served one at a time (see batamanta_daemon_server), so
    %% a single global slot is safe. It is cleared in the `after` below so
    %% a later request with no sink cannot write into a dead io_server.
    publish_stderr_sink(UserApp, StderrServer),
    Parent = self(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        OldGL = group_leader(),
        group_leader(StdoutServer, self()),
        %% Apply the caller's cwd if provided (per spec §"Componentes
        %% a implementar" — the wrapper passes the cwd of the user's
        %% shell, not the daemon's cwd, so file paths in the user app
        %% resolve the same as in a legacy invocation).
        apply_cwd(req_field(Req, <<"cwd">>, undefined)),
        Result = run_user_main(Req, UserApp, StderrServer),
        group_leader(OldGL, self()),
        Parent ! {self(), Result}
    end),
    %% Don't link: io_servers crashing must not take the worker down.
    unlink(StdoutServer),
    unlink(StderrServer),
    {Pid, MonRef, [StdoutServer, StderrServer]}.

%% `Alaja.Output` is the single place Alaja writes to stderr, and it
%% looks the sink up in persistent_term under this key. The atom is the
%% compiled Elixir module: 'Elixir.Alaja.Output'.
-define(STDERR_SINK_KEY, {'Elixir.Alaja.Output', stderr_sink}).

publish_stderr_sink(undefined, StderrServer) ->
    %% No user app (escript-shaped payload): the global slot is still
    %% worth setting, so components that print errors are captured.
    persistent_term:put(?STDERR_SINK_KEY, StderrServer),
    ok;
publish_stderr_sink(UserApp, StderrServer) ->
    application:set_env(UserApp, batamanta_daemon_stderr, StderrServer),
    persistent_term:put(?STDERR_SINK_KEY, StderrServer),
    ok.

%% Both sinks are per-request state and must not outlive it. The app env
%% is what a consumer's own code may read; the persistent_term key is the
%% global slot `Alaja.Output` consults. Left behind, a later request with
%% no sink would write into a dead io_server.
clear_stderr_sink() ->
    application:unset_env(alaja, batamanta_daemon_stderr),
    _ = persistent_term:erase(?STDERR_SINK_KEY),
    ok.

%% Stop the io_servers and WAIT for them to flush.
%%
%% Sending `stop` and returning immediately was a race: the `after` block
%% in run/3 deletes the capture table as soon as wait_for_worker returns,
%% but the io_servers process their mailbox at their own pace, so a late
%% flush hit a dead table and the daemon logged
%%   ** (ArgumentError) the table identifier does not refer to an existing
%%      ETS table
%% and every request came back exit code 1.
stop_io_servers(Servers) when is_list(Servers) ->
    lists:foreach(fun stop_io_server/1, Servers);
stop_io_servers(_) ->
    ok.

stop_io_server(Pid) ->
    Ref = make_ref(),
    Pid ! {stop, self(), Ref},
    receive
        {io_server_stopped, Ref} -> ok
    after ?IO_FLUSH_TIMEOUT_MS ->
        ok
    end.

wait_for_worker(Pid, MonRef, Servers, Table, TimeoutMs) ->
    receive
        {Pid, {ok, ExitCode}} ->
            erlang:demonitor(MonRef, [flush]),
            stop_io_servers(Servers),
            assemble_result(Table, ExitCode);
        {Pid, {error, _} = E} ->
            erlang:demonitor(MonRef, [flush]),
            stop_io_servers(Servers),
            E;
        {Pid, {crashed, Class, Reason}} ->
            erlang:demonitor(MonRef, [flush]),
            stop_io_servers(Servers),
            Msg = iolist_to_binary(
                    io_lib:format("runner crashed: ~p:~p~n", [Class, Reason])),
            Stderr = read_stderr(Table),
            {ok, 1, read_stdout(Table), <<Stderr/binary, Msg/binary>>};
        {'DOWN', MonRef, process, Pid, normal} ->
            stop_io_servers(Servers),
            {ok, 0, read_stdout(Table), read_stderr(Table)};
        {'DOWN', MonRef, process, Pid, Reason} ->
            stop_io_servers(Servers),
            Stderr = read_stderr(Table),
            Msg = iolist_to_binary(
                    io_lib:format("worker died: ~p~n", [Reason])),
            {ok, 1, read_stdout(Table), <<Stderr/binary, Msg/binary>>}
    after TimeoutMs ->
        exit(Pid, kill),
        stop_io_servers(Servers),
        Stderr = read_stderr(Table),
        Msg = iolist_to_binary(
                io_lib:format("request timeout after ~pms~n", [TimeoutMs])),
        {ok, 124, read_stdout(Table), <<Stderr/binary, Msg/binary>>}
    end.

assemble_result(Table, ExitCode) ->
    {ok, ExitCode, read_stdout(Table), read_stderr(Table)}.

%% ============================================================================
%% User main invocation
%% ============================================================================

%% The request arrives from `json:decode/1`, so its keys are BINARIES.
%% Pattern-matching or fetching atom keys raised
%%   ** (FunctionClauseError) no function clause matching in run_user_main/3
%% on every single request: the worker reported exit code 1 and the
%% wrapper then misread it as a daemon failure. One helper keeps the key
%% shape in a single place so it cannot drift again.
req_field(Req, BinKey, Default) when is_map(Req) ->
    maps:get(BinKey, Req, Default);
req_field(_Req, _BinKey, Default) ->
    Default.

run_user_main(Req, UserApp, StderrServer) ->
    Args = req_field(Req, <<"args">>, []),
    %% Semantic: by the time we reach here, either
    %%   (a) the user app is already running as part of the release boot
    %%       (because the wrapper invoked `bin/<app> foreground` which
    %%       starts the configured OTP apps — including the user's), or
    %%   (b) we're running an escript-shaped payload where there's no
    %%       user app to start, just a CLI module to call.
    %%
    %% In both cases we just invoke the CLI module — no
    %% `application:ensure_all_started` here, because that would
    %% double-start supervisors. If a CLI tool needs a fresh slate per
    %% call, that's its own contract: it can `stop` its own processes
    %% before returning from `main/1`.
    %%
    %% The effective user app is the REQUEST's, falling back to this
    %% daemon's own build. A warm daemon keeps the environment it booted
    %% with, so trusting the env alone would dispatch every request to
    %% whichever app/CLI this VM was built for.
    EffectiveApp = request_user_app(Req, UserApp),
    apply_terminal_hint(Req, EffectiveApp),
    case EffectiveApp of
        undefined ->
            invoke_cli(Req, Args, StderrServer);
        _ ->
            case application:load(EffectiveApp) of
                ok -> invoke_cli(Req, Args, StderrServer);
                {error, {already_loaded, EffectiveApp}} -> invoke_cli(Req, Args, StderrServer);
                {error, Reason} -> {error, {user_app_not_loadable, EffectiveApp, Reason}}
            end
    end.

request_user_app(Req, Fallback) ->
    case req_field(Req, <<"user_app">>, <<>>) of
        A when is_binary(A), A =/= <<>> -> list_to_atom(binary_to_list(A));
        _ -> Fallback
    end.

%% The daemon buffers output through its own io_server, so anything the
%% user app decides from `IO.ANSI.enabled?/0` sees a non-terminal and
%% strips every colour. The caller knows what ITS stdout is, so it says
%% so in the request and we push that down as an app env override.
%%
%% Set on EVERY request, never once at boot: the same warm daemon serves
%% a terminal caller and a piped one in turn, and a stale `always` would
%% emit escape codes into a file or a pipe.
%%
%% Skipped when there is no user app to configure (escript-shaped
%% payloads, where the CLI module is invoked without one).
apply_terminal_hint(_Req, undefined) ->
    ok;
apply_terminal_hint(Req, UserApp) ->
    %% Mark ourselves so the user app can adapt. A CLI generated with
    %% `halt_on_error: true` calls System.halt(1) on an error, and halt is
    %% uncatchable: it would take the whole warm BEAM down, the client
    %% would see the connection drop mid-request and re-run the command in
    %% the foreground. Returning the error normally instead lets the daemon
    %% reply with the exit code and stay warm.
    application:set_env(UserApp, batamanta_daemon, true),
    case req_field(Req, <<"tty">>, null) of
        true  -> application:set_env(UserApp, color, always);
        false -> application:set_env(UserApp, color, never);
        _     -> application:unset_env(UserApp, color)
    end.

invoke_cli(Req, Args, StderrServer) ->
    %% Prefer the CALLER's CLI module. This daemon's own baked module is
    %% only a fallback for older wrappers that do not send the field.
    Hint =
        case req_field(Req, <<"cli_module">>, <<>>) of
            M when is_binary(M), M =/= <<>> -> cli_module_candidates(binary_to_list(M));
            _ -> env_cli_module()
        end,
    Candidates = candidates_for(Hint, Req),
    case find_main_fun(Candidates) of
        {ok, FunMod} ->
            try
                Code = FunMod:main(Args),
                {ok, exit_code(Code)}
            catch
                Class:Reason ->
                    io:put_chars(StderrServer, unicode:characters_to_binary(
                        io_lib:format("uncaught ~p:~p~n", [Class, Reason]))),
                    {ok, 1}
            end;
        none ->
            Msg = iolist_to_binary(io_lib:format(
                "no CLI module found. Tried: ~p~n", [Candidates])),
            io:put_chars(StderrServer, Msg),
            {ok, 1}
    end.

env_cli_module() ->
    case os:getenv("BATAMANTA_DAEMON_CLI_MODULE", "") of
        "" -> undefined;
        EnvMod -> cli_module_candidates(EnvMod)
    end.

candidates_for(Hint, Req) ->
    Base = cli_candidates_for_user_app(Req),
    case Hint of
        undefined -> Base;
        _         -> Hint ++ Base
    end.

cli_candidates_for_user_app(Req) ->
    case request_user_app(Req, undefined) of
        undefined -> [];
        A         -> cli_candidates(A)
    end.

%% Elixir modules live under the `Elixir.' namespace: the module behind
%% the name "Alaja.CLI" is `Elixir.Alaja.CLI'. Building the atom straight
%% from the dotted string produced `Alaja.CLI', which matches no file on
%% disk, so `code:ensure_loaded/1' answered {:error, :nofile} and
%% `find_main_fun/1' could never succeed for ANY Elixir CLI. Every
%% request came back "no CLI module found" — which is every project in
%% this ecosystem, since they are all Elixir.
%%
%% Try the `Elixir.'-prefixed atom first and the bare one second, so a
%% hand-written Erlang module (a real `foo_cli.beam') still resolves.
name_variants(Name) when is_binary(Name) ->
    name_variants(binary_to_list(Name));
name_variants(Name) when is_list(Name) ->
    case lists:prefix("Elixir.", Name) of
        true  -> [list_to_atom(Name)];
        false -> [list_to_atom("Elixir." ++ Name), list_to_atom(Name)]
    end.

cli_module_candidates(ModName) ->
    name_variants(ModName).

cli_candidates(AppAtom) ->
    Name = atom_to_list(AppAtom),
    Title = titlecase(Name),
    lists:append([
        name_variants(Title ++ ".CLI"),
        name_variants(Title ++ ".Main"),
        [AppAtom]
    ]).

%% `erlang:function_exported/3` answers false for a module that is not
%% loaded YET, and the daemon boots with `start_clean`, so the user app's
%% modules sit on the code path without being loaded. Every candidate
%% therefore looked absent and the daemon replied
%%   no CLI module found. Tried: ['Alaja.CLI','Alaja.Main',alaja]
%% for a perfectly good CLI. Load the module before asking.
%%
%% Do NOT pattern-match the result of `code:ensure_loaded/1`. OTP 27
%% returns `{module, Mod}`; OTP 28 returns `[module: Mod]`, a one-element
%% keyword list. Matching the tuple silently matched nothing on OTP 28 and
%% every request came back "no CLI module found". Ask about main/1
%% afterwards instead, which is the same on both.
find_main_fun([]) -> none;
find_main_fun([M | Rest]) ->
    _ = code:ensure_loaded(M),
    case erlang:function_exported(M, main, 1) of
        true -> {ok, M};
        false -> find_main_fun(Rest)
    end.

%% A `main/1` that returns `nil` (the atom `nil`, as Elixir spells it) or
%% `ok` succeeded. This is the common shape for a DSL-generated entry
%% point: alaja's own `Alaja.CLI.Definition` emits
%%
%%     result = ...
%%     if match?({:error, _}, result), do: System.halt(1)
%%
%% and the `if` has no `else`, so the function returns `nil` on every
%% successful run. Mapping that to 1 made a perfectly healthy daemon
%% report failure to the shell, so `alaja --version && ...` broke while
%% the output looked correct.
exit_code(0) -> 0;
exit_code(nil) -> 0;
exit_code(ok) -> 0;
exit_code(true) -> 0;
exit_code(N) when is_integer(N), N >= 0, N =< 255 -> N;
exit_code(N) when is_integer(N) -> N rem 256;
exit_code({ok, _}) -> 0;
exit_code({error, _}) -> 1;
exit_code(_) -> 1.

titlecase([C | T]) when C >= $a, C =< $z -> [C - 32 | T];
titlecase(S) -> S.

%% NOTE: the "is the first argument a module name?" heuristic that used
%% to live here is gone. A CLI's first argument is a SUBCOMMAND, so
%% `alaja success "x"` was read as a request for the module `Success`,
%% and the candidate list filled with 'Success.CLI', 'Success.Main' and
%% `success` — none of which exist. The module to invoke comes from the
%% request's `cli_module` (the caller knows it) or from the user app name
%% (the conventional `<App>.CLI`); the arguments are never mined for it.

%% ============================================================================
%% cwd handling (per spec §"Componentes a implementar" — the wrapper
%% passes the caller's cwd and the daemon honours it so file paths in
%% the user app resolve the same as in a legacy invocation).
%% ============================================================================

apply_cwd(undefined) -> ok;
apply_cwd(<<"">>)     -> ok;
apply_cwd(Cwd) when is_binary(Cwd) ->
    Path = binary_to_list(Cwd),
    case file:read_file_info(Path) of
        {ok, _} ->
            try
                file:set_cwd(Path),
                ok
            catch
                _:_ -> ok
            end;
        {error, _} ->
            %% Path doesn't exist or isn't accessible. Leave the daemon's
            %% cwd in place rather than failing the request — a relative
            %% file path that resolves to the user's cwd is a common CLI
            %% pattern, and the user may have set cwd for a future call
            %% to a path that's temporarily gone.
            ok
    end;
apply_cwd(_) -> ok.

%% ============================================================================
%% Output capture via custom group_leader / io_server
%%
%% This implements the Erlang `io` protocol in pure Erlang, writing every
%% chunk into an ETS row keyed by an internal counter. Both stdout and
%% stderr share the same table; the row key encodes which stream it came
%% from so we can split them at read time.
%% ============================================================================

%% ============================================================================
%% Output capture via custom group_leader / io_server

-define(ROW_STDOUT, 1).
-define(ROW_STDERR, 2).

start_io_server(Table, Kind) ->
    spawn_link(fun() -> io_server_loop(Table, Kind, <<>>) end).

io_server_loop(Table, Kind, Buffer) ->
    receive
        {io_request, From, ReplyAs, _Req} = Msg ->
            {Reply, NewBuffer} = handle_io(Msg, Buffer),
            From ! {io_reply, ReplyAs, Reply},
            io_server_loop(Table, Kind, NewBuffer);
        {'EXIT', _, _} ->
            flush_buffer(Table, Kind, Buffer),
            ok;
        {stop, From, Ref} ->
            flush_buffer(Table, Kind, Buffer),
            %% Acknowledge only AFTER the buffer is safely in ETS, so the
            %% caller knows it may read it (and may then delete the table).
            From ! {io_server_stopped, Ref},
            ok
    end.

handle_io({io_request, _From, _ReplyAs, {put_chars, _Enc, Mod, Fun, Args}}, Buffer) ->
    try
        Bin = unicode:characters_to_binary(Mod:Fun(Args)),
        {ok, <<Buffer/binary, Bin/binary>>}
    catch
        _:_ -> {{error, {put_chars_failed, Mod, Fun}}, Buffer}
    end;
handle_io({io_request, _From, _ReplyAs, {put_chars, _Enc, Bin}}, Buffer) ->
    {ok, <<Buffer/binary, Bin/binary>>};
handle_io({io_request, _From, _ReplyAs, {put_chars, Bin}}, Buffer) ->
    {ok, <<Buffer/binary, Bin/binary>>};
handle_io({io_request, _From, _ReplyAs, get_until}, Buffer) ->
    %% Stdin-style requests aren't supported — return eof so callers
    %% stop reading rather than blocking.
    {{error, get_until_not_supported}, Buffer};
handle_io({io_request, _From, _ReplyAs, get_line}, Buffer) ->
    {{error, get_line_not_supported}, Buffer};
handle_io({io_request, _From, _ReplyAs, get_chars}, Buffer) ->
    {{error, get_chars_not_supported}, Buffer};
handle_io({io_request, _From, _ReplyAs, get_geometry}, Buffer) ->
    {{ok, 80, 24}, Buffer};
handle_io({io_request, _From, _ReplyAs, set_geometry}, Buffer) ->
    {{ok, 80, 24}, Buffer};
handle_io({io_request, _From, _ReplyAs, requests}, Buffer) ->
    %% List of supported io_requests. We're a write-only sink; declare
    %% only the put_chars family so callers don't try to read from us.
    {{ok, [requests, {put_chars, unicode}]}, Buffer};
handle_io({io_request, _From, _ReplyAs, _Other}, Buffer) ->
    {{error, unsupported_io_request}, Buffer}.

flush_buffer(_Table, _Kind, <<>>) -> ok;
flush_buffer(Table, Kind, Bin) when is_binary(Bin) ->
    %% Defensive: a late flush (worker killed, VM shutting down) can find
    %% the table already gone. Losing captured output is strictly better
    %% than taking down the request with a badarg.
    try
        Counter = ets:update_counter(Table, seq, 1, {seq, 0}),
        Key = case Kind of
            stdout -> {?ROW_STDOUT, Counter};
            stderr -> {?ROW_STDERR, Counter}
        end,
        ets:insert(Table, {Key, Bin}),
        ok
    catch
        error:badarg -> ok
    end.

read_stdout(Table) -> read_stream(Table, ?ROW_STDOUT).
read_stderr(Table) -> read_stream(Table, ?ROW_STDERR).

read_stream(Table, Row) ->
    Keys = [K || {K, _} <- ets:match_object(Table, {{Row, '_'}, '_'})],
    Sorted = lists:sort(Keys),
    Bin = lists:foldl(fun(K, Acc) ->
        case ets:lookup(Table, K) of
            [{_, B}] when is_binary(B) -> <<Acc/binary, B/binary>>;
            _ -> Acc
        end
    end, <<>>, Sorted),
    Bin.

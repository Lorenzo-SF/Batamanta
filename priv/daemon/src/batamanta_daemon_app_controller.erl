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
    Parent = self(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        OldGL = group_leader(),
        group_leader(StdoutServer, self()),
        %% Apply the caller's cwd if provided (per spec §"Componentes
        %% a implementar" — the wrapper passes the cwd of the user's
        %% shell, not the daemon's cwd, so file paths in the user app
        %% resolve the same as in a legacy invocation).
        apply_cwd(maps:get(cwd, Req, undefined)),
        Result = run_user_main(Req, UserApp, StderrServer),
        group_leader(OldGL, self()),
        Parent ! {self(), Result}
    end),
    %% Don't link: io_servers crashing must not take the worker down.
    unlink(StdoutServer),
    unlink(StderrServer),
    {Pid, MonRef, [StdoutServer, StderrServer]}.

stop_io_servers([]) -> ok;
stop_io_servers([Pid | Rest]) ->
    Pid ! stop,
    stop_io_servers(Rest).

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

run_user_main(#{args := Args}, UserApp, StderrServer) ->
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
    case UserApp of
        undefined ->
            invoke_cli(Args, StderrServer);
        _ ->
            case application:load(UserApp) of
                ok -> invoke_cli(Args, StderrServer);
                {error, {already_loaded, UserApp}} -> invoke_cli(Args, StderrServer);
                {error, Reason} -> {error, {user_app_not_loadable, UserApp, Reason}}
            end
    end.

invoke_cli(Args, StderrServer) ->
    CliModule =
        case os:getenv("BATAMANTA_DAEMON_CLI_MODULE", "") of
            "" -> undefined;
            EnvMod -> list_to_atom(EnvMod)
        end,
    Candidates = candidates_for(Args, CliModule),
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

candidates_for(Args, Hint) ->
    Auto = case Args of
        [First | _] when is_binary(First) ->
            case is_module_name(First) of
                true  -> cli_candidates(list_to_atom(binary_to_list(First)));
                false -> cli_candidates_for_user_app()
            end;
        _ ->
            cli_candidates_for_user_app()
    end,
    case Hint of
        undefined -> Auto;
        M         -> [M | Auto]
    end.

cli_candidates_for_user_app() ->
    case os:getenv("BATAMANTA_DAEMON_USER_APP", "") of
        "" -> [];
        A  -> cli_candidates(list_to_atom(A))
    end.

cli_candidates(AppAtom) ->
    Name = atom_to_list(AppAtom),
    [
        list_to_atom(titlecase(Name) ++ ".CLI"),
        list_to_atom(titlecase(Name) ++ ".Main"),
        AppAtom
    ].

find_main_fun([]) -> none;
find_main_fun([M | Rest]) ->
    case erlang:function_exported(M, main, 1) of
        true -> {ok, M};
        false -> find_main_fun(Rest)
    end.

exit_code(0) -> 0;
exit_code(N) when is_integer(N), N >= 0, N =< 255 -> N;
exit_code(N) when is_integer(N) -> N rem 256;
exit_code(_) -> 1.

titlecase([C | T]) when C >= $a, C =< $z -> [C - 32 | T];
titlecase(S) -> S.

is_module_name(Bin) when is_binary(Bin) ->
    Size = byte_size(Bin),
    Size > 0 andalso is_alpha(binary:at(Bin, 0))
        andalso is_atom_chars(Size, Bin);
is_module_name(_) -> false.

is_atom_chars(Size, Bin) ->
    is_atom_chars(Size, Bin, 1).

is_atom_chars(Size, _Bin, I) when I >= Size -> true;
is_atom_chars(Size, Bin, I) ->
    C = binary:at(Bin, I),
    case is_alpha(C) orelse (C >= $0 andalso C =< $9) orelse C =:= $. orelse C =:= $_ of
        true -> is_atom_chars(Size, Bin, I + 1);
        false -> false
    end.

is_alpha(C) when C >= $A, C =< $Z -> true;
is_alpha(C) when C >= $a, C =< $z -> true;
is_alpha(_) -> false.

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
        stop ->
            flush_buffer(Table, Kind, Buffer),
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
    Counter = ets:update_counter(Table, seq, 1, {seq, 0}),
    Key = case Kind of
        stdout -> {?ROW_STDOUT, Counter};
        stderr -> {?ROW_STDERR, Counter}
    end,
    ets:insert(Table, {Key, Bin}),
    ok.

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

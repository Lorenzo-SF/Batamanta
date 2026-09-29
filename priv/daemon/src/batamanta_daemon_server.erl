-module(batamanta_daemon_server).
-behaviour(gen_server).

%% @doc Unix-domain-socket server for the BEAM daemon.
%%
%% Lifecycle:
%%   * `init/1` binds `gen_tcp:listen` on AF_UNIX, writes the PID file,
%%     schedules the inactivity timer.
%%   * Each accepted connection reads exactly one length-prefixed frame.
%%   * The frame is dispatched: `req` runs the user CLI; `ping` is a
%%     liveness probe; `shutdown` asks for a clean exit.
%%   * The build_hash in the request must match the daemon's baked hash;
%%     otherwise the daemon replies with `{ok, false, error=hash_mismatch}`
%%     and shuts itself down — the wrapper will spawn a fresh one.
%%
%% Concurrency: FIFO/1. The server processes one request at a time. New
%% requests are queued in `gen_server` order (FIFO by arrival). This is
%% safe for typical CLI tools whose supervision tree is not reentrant.

-include_lib("kernel/include/inet.hrl").
-include("batamanta_daemon.hrl").

-export([start_link/1, init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {
    sock_path    :: string(),
    pid_file     :: string(),
    user_app     :: atom() | undefined,
    request_timeout_ms :: pos_integer(),
    default_ttl_ms :: non_neg_integer(),
    build_hash   :: string(),
    identity     :: string(),
    listen_socket :: port(),
    timer        :: reference() | undefined,
    queue        :: list(),   %% [{ConnPid, WorkerPid, Req}]
    running      :: boolean(),
    %% Set when a request was rejected. The server answers that request
    %% first and only stops on the next message, so the reply reaches the
    %% client before the daemon goes away.
    rejected     :: term() | undefined
}).

-type state() :: #state{}.

%% ============================================================================
%% Public API
%% ============================================================================

start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(#{sock_path := SockPath,
       pid_file := PidFile,
       user_app := UserApp,
       request_timeout_ms := TimeoutMs,
       default_ttl_ms := TTLMs,
       build_hash := BuildHash,
       identity := Identity}) ->
    process_flag(trap_exit, true),
    case gen_tcp:listen(0, [
        {ifaddr, {local, SockPath}},
        binary,
        {active, false},
        {packet, 0},
        {reuseaddr, false}
    ]) of
        {ok, ListenSock} ->
            %% Restrict socket permissions: only the owning UID can connect.
            file:change_mode(SockPath, 8#600),
            %% Same for the directory (per spec §"Seguridad").
            case file:change_mode(filename:dirname(SockPath), 8#700) of
                ok -> ok;
                {error, _} -> ok  %% May not own the dir; socket perms are what matter
            end,
            write_pid_file(PidFile),
            Timer = schedule_inactivity(TTLMs),
            Server = self(),
            %% Prime the accept loop. Without it nothing ever calls
            %% gen_tcp:accept/1, so the socket exists and the wrapper
            %% connects and writes a frame that nobody reads: the
            %% dispatch then blocks until the client gives up. The
            %% daemon looked healthy (socket bound, pid file written)
            %% while being completely inert.
            spawn(fun() -> accept_loop(ListenSock, Server) end),
            {ok, #state{
                sock_path = SockPath,
                pid_file = PidFile,
                user_app = UserApp,
                request_timeout_ms = TimeoutMs,
                default_ttl_ms = TTLMs,
                build_hash = BuildHash,
                identity = Identity,
                listen_socket = ListenSock,
                timer = Timer,
                queue = [],
                running = false,
                rejected = undefined
            }};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

%% ============================================================================
%% Accept loop + connection handling
%% ============================================================================
%%
%% The gen_server owns the state and the request queue; it must never
%% block, so accepting happens in a plain spawned process. Each accepted
%% socket gets its own process that reads exactly one length-prefixed
%% frame, hands it to the server, and writes back the reply the server
%% sends it. That matches the message contract the rest of this module
%% already assumed: the server notifies the connection process with
%% {ServerPid, running | queued} and later {ServerPid, reply, Reply}.
%%
%% Errors are logged, never propagated: a bad client must not take the
%% daemon down, and the server's inactivity timer is what ends its life.

accept_loop(ListenSock, Server) ->
    case gen_tcp:accept(ListenSock) of
        {ok, Sock} ->
            _ = spawn(fun() -> handle_connection(Sock, Server) end),
            accept_loop(ListenSock, Server);
        {error, closed} ->
            ok;  %% server shutting down
        {error, Reason} ->
            error_logger:error_msg("batamanta_daemon accept failed: ~p~n", [Reason]),
            timer:sleep(100),
            accept_loop(ListenSock, Server)
    end.

handle_connection(Sock, Server) ->
    try
        case read_frame(Sock) of
            {ok, Req} ->
                _ = gen_server:call(Server, {request, self(), Req}, infinity),
                %% The server answers the call immediately (ok) and the
                %% real reply arrives later as a message, once the
                %% request has run (or once it is rejected outright).
                receive
                    {Server, reply, Reply} ->
                        write_frame(Sock, Reply)
                end;
            {error, BadFrame} ->
                error_logger:error_msg("batamanta_daemon bad request: ~p~n", [BadFrame])
        end
    catch
        Class:Thrown:Stack ->
            error_logger:error_msg("batamanta_daemon connection crashed: ~p:~p~n~p~n",
                                   [Class, Thrown, Stack])
    after
        catch gen_tcp:close(Sock)
    end.

read_frame(Sock) ->
    case gen_tcp:recv(Sock, 4) of
        {ok, <<Len:32/big>>} when Len =< ?MAX_FRAME_BYTES ->
            case gen_tcp:recv(Sock, Len) of
                {ok, Body} ->
                    case batamanta_daemon_protocol:decode(
                           <<Len:32/big, Body/binary>>) of
                        {ok, Term, _Rest} -> {ok, Term};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, {short_body, Reason}}
            end;
        {ok, <<Len:32/big>>} ->
            {error, {frame_too_large, Len}};
        {error, Reason} ->
            {error, Reason}
    end.

write_frame(Sock, Term) ->
    case batamanta_daemon_protocol:encode(Term) of
        {ok, Bin} -> gen_tcp:send(Sock, Bin);
        {error, Reason} -> {error, Reason}
    end.

handle_call({request, ConnPid, Req}, _From, State) ->
    %% Compatibility gate. Two checks, cheapest discriminator first:
    %
    %%   * identity — the full build tuple (app, version, target,
    %%     format, exec mode, ERTS, CLI module). A daemon holds a BEAM
    %%     loaded from ITS payload and dispatches to the CLI module baked
    %%     at ITS startup, so a client with a different identity is not
    %%     merely stale, it is asking the wrong VM to do the wrong thing.
    %%     Sockets are already namespaced by identity, so reaching this
    %%     branch means the names collided anyway; refuse loudly.
    %%
    %%   * build_hash — same app+version+target+... but a different
    %%     payload (a redeploy, or a rebuild that changed a dep). Here
    %%     recycling IS the right answer, so we shut down and let the
    %%     wrapper spawn a fresh daemon.
    %%
    %% Both send a polite rejection frame first so the wrapper can act
    %% on the reason instead of guessing.
    case check_compatibility(Req, State) of
        ok ->
            NewState =
                case State#state.running of
                    true  -> enqueue(State, ConnPid, Req);
                    false -> run_next(ConnPid, Req, State)
                end,
            {reply, ok, NewState};
        {reject, Reason} ->
            %% MUST use send_reply/2. Sending `{self(), {reply, Map}}`
            %% here — a 2-tuple nested inside — does not match the
            %% `{Server, reply, Reply}` the connection process waits for,
            %% so the rejection was never delivered.
            send_reply(ConnPid, #{ok => false, error => Reason}),
            %% Return {reply, ok, ...} and stop on a LATER message
            %% instead of {stop, ...} here.
            %
            %% `{stop, Reason, State}` from handle_call/3 terminates
            %% abnormally, and a caller blocked in gen_server:call/3
            %% exits with the server's reason rather than consuming the
            %% reply. The connection process therefore died inside the
            %% call — before it could even reach its receive — so the
            %% client saw a bare EOF:
            %%   batamanta: daemon dispatch failed (read response)
            %% Only the accept path returned normally, which is why this
            %% showed up solely on hash_mismatch: right after a rebuild,
            %% when the payload changed but the socket identity
            %% (app/version/target/format/mode/erts/cli_module) did not.
            self() ! shutdown_rejected,
            {reply, ok, State#state{rejected = Reason}}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({tcp_closed, ConnPid}, State) ->
    NewState = cancel_running(State, ConnPid),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({request_done, ConnPid, Result}, State) ->
    NewState = on_request_done(ConnPid, Result, State),
    {noreply, NewState};
handle_info(timeout, State) ->
    _ = file:delete(State#state.sock_path),
    _ = file:delete(State#state.pid_file),
    {stop, normal, State};
handle_info(shutdown_rejected, #state{rejected = undefined} = State) ->
    {noreply, State};
handle_info(shutdown_rejected, #state{rejected = Reason} = State) ->
    {stop, {rejected, Reason}, State};
handle_info({'EXIT', _Pid, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    case is_running(State, Pid) of
        true ->
            ConnPid = case State#state.queue of
                [{Conn, _, _} | _] -> Conn;
                []                 -> undefined
            end,
            NewState = on_request_done(ConnPid, {error, {worker_died, Reason}}, State),
            {noreply, NewState};
        false ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% gen_tcp:close can throw if the socket is already closed; swallow
    %% the failure rather than corrupting the parent's shutdown.
    try gen_tcp:close(State#state.listen_socket)
    catch _:_ -> ok
    end,
    _ = file:delete(State#state.sock_path),
    _ = file:delete(State#state.pid_file),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ============================================================================
%% Request pipeline
%% ============================================================================

run_next(ConnPid, Req, State) ->
    NewTimer = reset_inactivity(State#state.default_ttl_ms),
    Self = self(),
    %% The user app and CLI module come from the REQUEST, not from this
    %% daemon's environment. A warm daemon keeps the environment it
    %% booted with, so reading them from `os:getenv/1` would silently
    %% dispatch every request to whatever module THIS daemon was built
    %% for — which is wrong the moment two clients with different CLI
    %% modules ever meet on one socket.
    Pid = spawn_link(fun() ->
        Result = batamanta_daemon_app_controller:run(Req,
                                                      State#state.user_app,
                                                      State#state.request_timeout_ms),
        Self ! {request_done, ConnPid, Result}
    end),
    ConnPid ! {self(), running},
    State#state{
        timer = NewTimer,
        running = true,
        queue = [{ConnPid, Pid, Req} | State#state.queue]
    }.

enqueue(State, ConnPid, Req) ->
    ConnPid ! {self(), queued},
    State#state{queue = State#state.queue ++ [{ConnPid, self(), Req}]}.

on_request_done(ConnPid, Result, State) ->
    Reply = build_response(Result),
    send_reply(ConnPid, Reply),
    NewQueue = strip_queue(ConnPid, State#state.queue),
    NewTimer = reset_inactivity(State#state.default_ttl_ms),
    case next_request(NewQueue) of
        none ->
            State#state{timer = NewTimer, running = false, queue = []};
        {NextConn, NextReq, Rest} ->
            run_next(NextConn, NextReq,
                     State#state{timer = NewTimer, queue = Rest})
    end.

%% The single place a connection process is answered. Both the happy path
%% and the rejection path go through here so the message shape cannot
%% drift apart again — see the reject branch in handle_call/3.
send_reply(ConnPid, Reply) ->
    ConnPid ! {self(), reply, Reply},
    ok.

cancel_running(State, ConnPid) ->
    case State#state.queue of
        [{ConnPid, WorkerPid, _} | Rest] ->
            exit(WorkerPid, kill),
            case Rest of
                [] ->
                    State#state{running = false, queue = []};
                [{NextConn, _, NextReq} | More] ->
                    run_next(NextConn, NextReq, State#state{queue = More})
            end;
        _ ->
            State
    end.

is_running(State, Pid) ->
    case State#state.queue of
        [{_, WorkerPid, _} | _] when WorkerPid =:= Pid -> true;
        _ -> false
    end.

%% ============================================================================
%% Inactivity timer
%% ============================================================================

schedule_inactivity(0) ->
    undefined;
schedule_inactivity(TTLMs) when TTLMs > 0 ->
    erlang:send_after(TTLMs, self(), timeout).

%% Pops the head of the queue, returning {none} when empty. Refactored
%% out of `on_request_done/3` because Erlang's case-of-case analysis
%% rejects a single `case` whose arms disagree on which variables they
%% bind (e.g. one arm binds Rest, another doesn't).
-spec next_request([tuple()]) -> none | {pid(), map(), [tuple()]}.
next_request([]) ->
    none;
next_request([{ConnPid, _WorkerPid, Req} | Rest]) ->
    {ConnPid, Req, Rest}.

%% Removes the entry for `ConnPid` from the queue, returning the tail.
%% Extracted so the case doesn't have to bind Rest in some arms and not
%% in others (unsafe under OTP 27+'s stricter Erlang compiler).
-spec strip_queue(pid(), [tuple()]) -> [tuple()].
strip_queue(_ConnPid, []) ->
    [];
strip_queue(ConnPid, [{ConnPid, _, _} | Rest]) ->
    Rest;
strip_queue(_ConnPid, [{_, _, _} | Rest]) ->
    Rest.

reset_inactivity(0) ->
    undefined;
reset_inactivity(TTLMs) when TTLMs > 0 ->
    erlang:send_after(TTLMs, self(), timeout).

%% ============================================================================
%% Compatibility checks
%% ============================================================================

check_compatibility(Req, State) ->
    case identity_matches(Req, State#state.identity) of
        false ->
            {reject, iolist_to_binary(io_lib:format(
                "identity_mismatch (req=~s, daemon=~s)",
                [req_identity(Req), State#state.identity]))};
        true ->
            ReqHash = maps:get(<<"build_hash">>, Req, <<>>),
            case hash_matches(ReqHash, State#state.build_hash) of
                true ->
                    ok;
                false ->
                    {reject, iolist_to_binary(io_lib:format(
                        "hash_mismatch (req=~s, daemon=~s)",
                        [ReqHash, State#state.build_hash]))}
            end
    end.

req_identity(Req) when is_map(Req) ->
    case maps:get(<<"identity">>, Req, <<>>) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end;
req_identity(_Req) ->
    <<>>.

%% Both sides are normalised to binaries before comparing. `os:getenv/1,2`
%% hands back a charlist while the request comes from `json:decode/1` as
%% binaries; a bare `is_binary/1` guard on the baked value silently
%% matched nothing and killed the server on the first request.
identity_matches(_Req, <<>>) ->
    true;
identity_matches(Req, Baked) when is_binary(Baked) ->
    Baked =:= req_identity(Req);
identity_matches(Req, Baked) when is_list(Baked) ->
    Baked =:= binary_to_list(req_identity(Req)).

hash_matches(_Req, <<>>) ->
    %% Empty daemon hash = legacy mode (no hash check). Should never
    %% happen in daemon mode but be defensive.
    true;
hash_matches(Req, Baked) when is_binary(Req) and is_binary(Baked) ->
    Req =:= Baked;
hash_matches(Req, Baked) when is_binary(Req) and is_list(Baked) ->
    binary_to_list(Req) =:= Baked;
hash_matches(_Req, _Baked) ->
    false.

%% ============================================================================
%% Response building
%% ============================================================================

build_response({ok, ExitCode, Stdout, Stderr}) ->
    #{
        ok => true,
        exit_code => ExitCode,
        stdout_b64 => base64:encode(Stdout),
        stderr_b64 => base64:encode(Stderr)
    };
build_response({error, Reason}) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    %% Keep it a BINARY. `json:encode/1` treats a charlist as a JSON
    %% array, so a `binary_to_list/1` here produced
    %% `{"ok":false,"error":[105,100,101,...]}` and the wrapper's
    %% `.and_then(|v| v.as_str())` fell back to "unknown" — every
    %% rejection reason was silently swallowed.
    #{
        ok => false,
        error => Msg
    }.

write_pid_file(Path) ->
    Pid = os:getpid(),
    Content = lists:flatten(io_lib:format("~s~n", [Pid])),
    ok = file:write_file(Path, Content).

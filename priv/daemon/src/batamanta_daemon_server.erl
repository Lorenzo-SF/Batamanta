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

-export([start_link/1, init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {
    sock_path    :: string(),
    pid_file     :: string(),
    user_app     :: atom() | undefined,
    request_timeout_ms :: pos_integer(),
    default_ttl_ms :: non_neg_integer(),
    build_hash   :: string(),
    listen_socket :: port(),
    timer        :: reference() | undefined,
    queue        :: list(),   %% [{ConnPid, WorkerPid, Req}]
    running      :: boolean()
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
       build_hash := BuildHash}) ->
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
            {ok, #state{
                sock_path = SockPath,
                pid_file = PidFile,
                user_app = UserApp,
                request_timeout_ms = TimeoutMs,
                default_ttl_ms = TTLMs,
                build_hash = BuildHash,
                listen_socket = ListenSock,
                timer = Timer,
                queue = [],
                running = false
            }};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call({request, ConnPid, Req}, _From, State) ->
    %% Hash gate: refuse requests from a wrapper with a mismatched hash.
    %% We send a polite rejection frame so the wrapper can respawn
    %% cleanly, then shut ourselves down. The wrapper will see no live
    %% socket on the next connect and bootstrap a fresh one.
    ReqHash = maps:get(<<"build_hash">>, Req, <<>>),
    case hash_matches(ReqHash, State#state.build_hash) of
        true ->
            NewState =
                case State#state.running of
                    true  -> enqueue(State, ConnPid, Req);
                    false -> run_next(ConnPid, Req, State)
                end,
            {reply, ok, NewState};
        false ->
            Reason = iolist_to_binary(io_lib:format(
                "hash_mismatch (req=~s, daemon=~s)",
                [ReqHash, State#state.build_hash])),
            ConnPid ! {self(), {reply, #{
                ok => false,
                error => binary_to_list(Reason)
            }}},
            {stop, hash_mismatch, State}
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
    catch gen_tcp:close(State#state.listen_socket),
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
    ConnPid ! {self(), reply, Reply},
    NewQueue = case State#state.queue of
        [{ConnPid, _, _} | Rest] -> Rest;
        [_ | Rest]               -> Rest;
        []                       -> []
    end,
    NewTimer = reset_inactivity(State#state.default_ttl_ms),
    case NewQueue of
        [] ->
            State#state{timer = NewTimer, running = false, queue = []};
        [{NextConn, _, NextReq} | Rest] ->
            run_next(NextConn, NextReq,
                     State#state{timer = NewTimer, queue = Rest})
    end.

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

reset_inactivity(0) ->
    undefined;
reset_inactivity(TTLMs) when TTLMs > 0 ->
    erlang:send_after(TTLMs, self(), timeout).

%% ============================================================================
%% Hash check
%% ============================================================================

hash_matches(_Req, "") ->
    %% Empty daemon hash = legacy mode (no hash check). Should never
    %% happen in daemon mode but be defensive.
    true;
hash_matches(Req, Baked) when is_binary(Req) ->
    ReqStr = binary_to_list(Req),
    ReqStr =:= Baked.

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
    #{
        ok => false,
        error => binary_to_list(Msg)
    }.

write_pid_file(Path) ->
    Pid = os:getpid(),
    Content = lists:flatten(io_lib:format("~s~n", [Pid])),
    ok = file:write_file(Path, Content).

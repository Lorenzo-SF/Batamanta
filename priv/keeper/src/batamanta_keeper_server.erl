-module(batamanta_keeper_server).
-behaviour(gen_server).

%% @doc gen_server for the BEAM alive mode Unix-socket listener.
%%
%% Phase 2 stub. Phase 4 implements:
%%   - gen_tcp:listen over AF_UNIX in init/1
%%   - accept loop with serial FIFO request handling
%%   - inactivity timer
%%   - restart policy
%%
%% See RFC-0008 §"Concurrencia" and §"Mecanismo de arranque".

-export([start_link/0, init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% Phase 2: no-op. The real init/1 in Phase 4 will bind the socket,
    %% write the PID file, and start the inactivity timer.
    {ok, #{phase => stub}}.

handle_call(_Msg, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

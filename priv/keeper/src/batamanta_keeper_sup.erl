-module(batamanta_keeper_sup).
-behaviour(supervisor).

%% @doc Supervisor for the BEAM alive mode keeper.
%%
%% Phase 2 stub: empty children. Phase 4 will add the gen_server with
%% the Unix-socket listener. See RFC-0008 §"Mecanismo de arranque".

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Phase 2: no children yet. The real listener (Phase 4) will be added here.
    {ok, {{one_for_one, 10, 10}, []}}.

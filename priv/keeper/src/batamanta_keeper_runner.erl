-module(batamanta_keeper_runner).

%% @doc Runs the user's CLI request inside the keeper BEAM.
%%
%% Phase 2 stub. Phase 5 implements:
%%   - application:load/1 + application:ensure_all_started/1 for the user app
%%   - spawn_monitor with timeout (BATAMANTA_REQUEST_TIMEOUT_MS, default 60s)
%%   - IO capture and propagation via group leader
%%   - exit code capture
%%
%% See RFC-0008 §"Concurrencia" and §"Manejo de stdout/stderr/exit code".

-export([version/0]).

version() ->
    "0.1.0-stub".

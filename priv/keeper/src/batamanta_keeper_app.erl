-module(batamanta_keeper_app).
-behaviour(application).

%% @doc OTP application callback for the Batamanta BEAM alive mode keeper.
%%
%% Phase 2 stub: starts a minimal supervisor with no children. The real
%% gen_server with the Unix-socket listener is added in Phase 4. This
%% module exists so that the keeper BEAM can be loaded as an OTP app
%% (entry in the user's release's applications list, or via -s).
%%
%% See RFC-0008 (rfcs/0008-beam-alive-mode.md) §"Módulos a crear/modificar".

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Phase 2: empty supervisor. Phase 4 will add the listener child.
    batamanta_keeper_sup:start_link().

stop(_State) ->
    ok.

-module(batamanta_daemon_sup).
-behaviour(supervisor).

%% @doc Supervisor for the BEAM daemon.
%%
%% Children:
%%   * `batamanta_daemon_server` — gen_server with the Unix socket and
%%     inactivity timer. The supervisor restarts it on crash so a single
%%     bad request doesn't take the whole daemon down.

-export([start_link/1, init/1]).

start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

init(Config) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 10},
    ChildSpecs = [
        #{id => batamanta_daemon_server,
          start => {batamanta_daemon_server, start_link, [Config]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [batamanta_daemon_server]}
    ],
    {ok, {SupFlags, ChildSpecs}}.

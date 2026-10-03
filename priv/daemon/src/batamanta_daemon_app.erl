-module(batamanta_daemon_app).
-behaviour(application).

%% @doc OTP application callback for the Batamanta BEAM daemon.
%%
%% The daemon is the persistent BEAM that stays alive between wrapper
%% invocations. It listens on a Unix-domain socket namespaced by
%% {app, version, target} and forwards each request to the user's app.
%%
%% See batamanta-daemon-mode-spec.md and rfcs/0008-beam-alive-mode.md
%% for the full design.

-export([start/2, stop/1]).

-include("batamanta_daemon.hrl").

start(_StartType, _StartArgs) ->
    case read_config() of
        {ok, Config} ->
            batamanta_daemon_sup:start_link(Config);
        {error, Reason} ->
            {error, Reason}
    end.

stop(_State) ->
    ok.

%% ---------------------------------------------------------------------------
%% Config
%% ---------------------------------------------------------------------------

read_config() ->
    SockPath  = os:getenv(?SOCK_PATH_ENV),
    PidFile   = os:getenv(?PID_FILE_ENV),
    UserApp   = os:getenv(?USER_APP_ENV, ""),
    Timeout   = os:getenv(?TIMEOUT_ENV, "60000"),
    TTL       = os:getenv(?TTL_ENV, "0"),
    %% os:getenv/1,2 returns a CHARLIST. These two are compared against
    %% values decoded from JSON, which are BINARIES, so keeping them as
    %% lists made `is_binary/1` guards in the server fail and killed it
    %% on the very first request:
    %%   ** (FunctionClauseError) no function clause matching in
    %%      :batamanta_daemon_server.identity_matches/2
    BuildHash = to_binary(os:getenv(?BUILD_HASH_ENV, "")),
    Identity  = to_binary(os:getenv(?IDENTITY_ENV, "")),

    case SockPath of
        false -> {error, {missing_env, ?SOCK_PATH_ENV}};
        []    -> {error, {empty_env, ?SOCK_PATH_ENV}};
        _ ->
            case PidFile of
                false -> {error, {missing_env, ?PID_FILE_ENV}};
                []    -> {error, {empty_env, ?PID_FILE_ENV}};
                _ ->
                    UserAppAtom =
                        case string:trim(UserApp) of
                            "" -> undefined;
                            A  -> list_to_atom(A)
                        end,
                    {ok, #{
                        sock_path => SockPath,
                        pid_file => PidFile,
                        user_app => UserAppAtom,
                        request_timeout_ms => parse_pos_int(Timeout, ?TIMEOUT_ENV, 60000),
                        default_ttl_ms => parse_non_neg_int(TTL, ?TTL_ENV, 0),
                        build_hash => BuildHash,
                        identity => Identity
                    }}
            end
    end.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V)  -> list_to_binary(V);
to_binary(_)                  -> <<>>.

parse_pos_int(S, _Var, Default) ->
    try list_to_integer(S) of
        N when N > 0 -> N;
        _ -> Default
    catch
        _:_ -> Default
    end.

parse_non_neg_int(S, _Var, Default) ->
    try list_to_integer(S) of
        N when N >= 0 -> N;
        _ -> Default
    catch
        _:_ -> Default
    end.

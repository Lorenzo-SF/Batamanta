-module(batamanta_daemon_app_controller_test).

%% @doc EUnit tests for `batamanta_daemon_app_controller:run/3`.
%%
%% These verify the per-request runner end-to-end: invocation of the
%% CLI module, exit-code propagation, stdout/stderr capture via the
%% swapped group leader, and exception handling. The runner is invoked
%% with `undefined` as the user_app so it skips `application:load/1` and
%% relies on `BATAMANTA_DAEMON_CLI_MODULE` to point at the test CLI.
%%
%% Run with:
%%
%%     erlc -o /tmp priv/daemon/src/*.erl priv/daemon/include/*.hrl \
%%                   priv/daemon/test/*.erl
%%     erl -pa /tmp -eval 'eunit:test([{module, batamanta_daemon_app_controller}])'

-include_lib("eunit/include/eunit.hrl").

-define(CLI_MOD, batamanta_daemon_test_cli).

run_captures_stdout_test_() ->
    {setup,
     fun setup/0, fun cleanup/1,
     fun() ->
         Req = #{args => [<<"hello">>],
                 env => #{},
                 cwd => undefined,
                 stdin_b64 => undefined},
         {ok, 0, Stdout, Stderr} =
             batamanta_daemon_app_controller:run(Req, undefined, 5000),
         ?_assertEqual(<<"hello-from-cli\n">>, Stdout)
         and ?_assertEqual(<<>>, Stderr)
     end}.

run_returns_exit_code_test_() ->
    {setup,
     fun setup/0, fun cleanup/1,
     fun() ->
         Req = #{args => [<<"exit42">>],
                 env => #{},
                 cwd => undefined,
                 stdin_b64 => undefined},
         {ok, 42, _, _} =
             batamanta_daemon_app_controller:run(Req, undefined, 5000)
     end}.

run_catches_user_crash_test_() ->
    {setup,
     fun setup/0, fun cleanup/1,
     fun() ->
         Req = #{args => [<<"boom">>],
                 env => #{},
                 cwd => undefined,
                 stdin_b64 => undefined},
         {ok, 1, _, Stderr} =
             batamanta_daemon_app_controller:run(Req, undefined, 5000),
         ?_assert(byte_size(Stderr) > 0)
     end}.

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

setup() ->
    %% Make sure the test CLI module is loaded.
    code:ensure_loaded(?CLI_MOD),
    %% Point the runner at it via the env-var override.
    os:putenv("BATAMANTA_DAEMON_CLI_MODULE", atom_to_list(?CLI_MOD)),
    ok.

cleanup(_) ->
    os:unsetenv("BATAMANTA_DAEMON_CLI_MODULE"),
    ok.

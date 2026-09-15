-module(batamanta_daemon_test_cli).

%% @doc Minimal CLI module used by the EUnit tests for
%% `batamanta_daemon_app_controller:run/3`. Not shipped in the payload.

-export([main/1]).

main([<<"hello">>]) ->
    io:format("hello-from-cli~n"),
    0;
main([<<"exit42">>]) ->
    42;
main([<<"boom">>]) ->
    error(intentional_test_crash).

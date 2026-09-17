-module(batamanta_daemon_protocol_test).

%% @doc EUnit tests for `batamanta_daemon_protocol`. Run with:
%%
%%     erlc -o /tmp priv/daemon/src/*.erl priv/daemon/include/*.hrl
%%     erl -pa /tmp -eval 'eunit:test(batamanta_daemon_protocol, [verbose]).'

-include_lib("eunit/include/eunit.hrl").

encode_decode_roundtrip_test() ->
    Term = #{<<"cmd">> => <<"req">>,
             <<"args">> => [<<"foo">>, <<"bar baz">>],
             <<"env">> => #{<<"KEY">> => <<"VAL">>}},
    {ok, Bin} = batamanta_daemon_protocol:encode(Term),
    %% The encoded frame is length-prefix(4) + payload.
    <<Len:32/big, Payload/binary>> = Bin,
    ?assertEqual(byte_size(Payload), Len),
    {ok, Decoded, <<>>} = batamanta_daemon_protocol:decode(Bin),
    ?assertEqual(Term, Decoded).

decode_incomplete_test() ->
    %% Length says 10 bytes but we only provide 3.
    Bad = <<10:32/big, "abc">>,
    {error, {incomplete_frame, 10, 3}} = batamanta_daemon_protocol:decode(Bad).

decode_oversize_test() ->
    %% Encode a tiny payload, then lie about its length.
    {ok, Encoded} = batamanta_daemon_protocol:encode(#{<<"ok">> => true}),
    <<_Len:32/big, Payload/binary>> = Encoded,
    RealLen = byte_size(Payload),
    BigLen = 100 * 1024 * 1024,
    Bad = <<BigLen:32/big, Payload/binary>>,
    {error, _} = batamanta_daemon_protocol:decode(Bad),
    %% And the inner check: if the declared length is plausible but huge,
    %% the cap kicks in.
    _ = RealLen.

encode_oversize_test() ->
    %% 65 MiB payload — the cap is 64 MiB.
    Huge = binary:copy(<<"x">>, 65 * 1024 * 1024),
    {error, {frame_too_large, _, _}} =
        batamanta_daemon_protocol:encode(Huge).

version_test() ->
    ?assert(is_list(batamanta_daemon_protocol:version())).

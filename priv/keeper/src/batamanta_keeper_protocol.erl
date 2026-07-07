-module(batamanta_keeper_protocol).

%% @doc Encode/decode of the request/response protocol over the Unix socket.
%%
%% Phase 2 stub. Phase 4 implements:
%%   - decode_request/1: line-by-line REQ protocol with stdin framing
%%   - encode_response/1: length-prefixed RSP with stdout/stderr blobs
%%
%% See RFC-0008 §"Protocolo de comunicación".

-export([version/0]).

version() ->
    "0.1.0-stub".

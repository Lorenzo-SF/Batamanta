-module(batamanta_daemon_protocol).

%% @doc Wire protocol for the Unix-domain-socket daemon.
%%
%% Frame format (both directions):
%%
%%     +-------------------- 4 bytes: big-endian payload length N
%%     +-------------------- N bytes: JSON payload
%%
%% Request payload (client -> daemon):
%%
%%     {
%%       "cmd": "req",
%%       "args": ["foo", "bar"],
%%       "env":  {"KEY": "VALUE", ...},
%%       "cwd":  "/path/to/cwd",        %% optional; if missing the daemon uses its own cwd
%%       "stdin_b64": "<base64>",       %% optional stdin payload
%%       "build_hash": "<12-hex-chars>" %% matches daemon's baked hash; mismatch = shutdown
%%     }
%%
%% Response payload (daemon -> client):
%%
%%     {
%%       "ok": true,
%%       "exit_code": 0,
%%       "stdout_b64": "<base64>",
%%       "stderr_b64": "<base64>"
%%     }
%%
%% Or on protocol / fatal error:
%%
%%     {
%%       "ok": false,
%%       "error": "reason_atom_or_string"
%%     }
%%
%% This module only handles encoding/decoding JSON over length-prefixed
%% frames — it does NOT do socket I/O. The server is responsible for the
%% recv/send loop.

-export([encode/1, decode/1, version/0]).

-define(MAGIC_LEN, 4).
-define(MAX_FRAME, 64 * 1024 * 1024).  %% 64 MiB hard cap (matches RFC spec).

%% ============================================================================
%% Public API
%% ============================================================================

-spec version() -> string().
version() -> "0.1.0".

%% @doc Encode a JSON-encodable term into a 4-byte length prefix + payload.
-spec encode(term()) -> {ok, binary()} | {error, term()}.
encode(Term) ->
    Json = json_encode(Term),
    Len = byte_size(Json),
    case Len =< ?MAX_FRAME of
        true ->
            Prefix = <<Len:32/big>>,
            {ok, <<Prefix/binary, Json/binary>>};
        false ->
            {error, {frame_too_large, Len, ?MAX_FRAME}}
    end.

%% @doc Decode a 4-byte-prefixed + payload binary into the original term.
-spec decode(binary()) ->
    {ok, term(), Rest :: binary()} | {error, term()}.
decode(<<Len:32/big, Rest/binary>>) when Len =< ?MAX_FRAME ->
    case Rest of
        <<Payload:Len/binary, Rest2/binary>> ->
            try json_decode(Payload) of
                Term -> {ok, Term, Rest2}
            catch
                Class:Reason ->
                    {error, {invalid_json, Class, Reason}}
            end;
        _ when byte_size(Rest) < Len ->
            {error, {incomplete_frame, Len, byte_size(Rest)}};
        _ ->
            {error, {frame_too_large, Len, ?MAX_FRAME}}
    end;
decode(_) ->
    {error, missing_length_prefix}.

%% ============================================================================
%% JSON via OTP's `json` module (OTP 27+)
%% ============================================================================
%%
%% OTP 27 introduced `json` as a stdlib module. Earlier OTPs don't have it
%% in stdlib (only as a separate dep). Batamanta's ERTS floor is 27+, so
%% we can rely on it being present.

json_encode(Term) ->
    try
        json:encode(Term)
    catch
        Class:Reason ->
            error({json_encode_failed, Class, Reason, Term})
    end.

json_decode(Bin) ->
    try
        json:decode(Bin)
    catch
        Class:Reason ->
            error({json_decode_failed, Class, Reason})
    end.

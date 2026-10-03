%% Common records and macros for the Batamanta daemon.
%%
%% Per RFC-0008-bis (batamanta-daemon-mode-spec.md):
%%
%%   * Socket path: $XDG_RUNTIME_DIR/batamanta/<basename>.sock
%%     (fallback /tmp/batamanta/<basename>.sock when XDG is not set,
%%     e.g. in containers or unusual environments)
%%   * `<basename>` comes from `Batamanta.Daemon.runtime_basename/1` and
%%     is `<app>-<version>-e<erts>-<digest>`, where the digest covers the
%%     whole compatibility tuple. Two binaries may share a daemon only
%%     when ALL of these match:
%%
%%         app · version · target · format · exec_mode · erts · cli_module
%%
%%     `target` is the rust triple, so OS+arch+libc are covered (a
%%     linux-gnu and a linux-musl build of one app can coexist on one
%%     machine). `erts` was the field that used to be missing: two
%%     builds of the same app+version+target differing only in their
%%     bundled ERTS shared one socket, every request came back
%%     `hash_mismatch`, the daemon recycled, and the feature cost full
%%     price for no benefit.
%%
%% The Rust wrapper sets these env vars before exec'ing erlexec:
%%
%%   BATAMANTA_DAEMON_SOCK_PATH   — absolute path of the AF_UNIX socket
%%   BATAMANTA_DAEMON_PID_FILE    — path to write the daemon PID
%%   BATAMANTA_DAEMON_APP_NAME    — e.g. "my_cli"
%%   BATAMANTA_DAEMON_APP_VERSION — e.g. "0.1.0"
%%   BATAMANTA_DAEMON_TARGET      — e.g. "linux-glibc-x86_64"
%%   BATAMANTA_DAEMON_USER_APP    — OTP application to load per request
%%   BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS — per-request timeout (default 60000)
%%   BATAMANTA_DAEMON_DEFAULT_TTL_MS    — inactivity timeout (default 0 = off)
%%   BATAMANTA_DAEMON_BUILD_HASH  — 12-hex-char build hash for staleness check
%%   BATAMANTA_DAEMON_IDENTITY    — full compatibility tuple, echoed on
%%                                  every request and checked by the server

-define(SOCK_PATH_ENV,    "BATAMANTA_DAEMON_SOCK_PATH").
-define(PID_FILE_ENV,     "BATAMANTA_DAEMON_PID_FILE").
-define(APP_NAME_ENV,     "BATAMANTA_DAEMON_APP_NAME").
-define(APP_VERSION_ENV,  "BATAMANTA_DAEMON_APP_VERSION").
-define(TARGET_ENV,       "BATAMANTA_DAEMON_TARGET").
-define(USER_APP_ENV,     "BATAMANTA_DAEMON_USER_APP").
-define(TIMEOUT_ENV,      "BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS").
-define(TTL_ENV,          "BATAMANTA_DAEMON_DEFAULT_TTL_MS").
-define(BUILD_HASH_ENV,   "BATAMANTA_DAEMON_BUILD_HASH").
-define(IDENTITY_ENV,     "BATAMANTA_DAEMON_IDENTITY").

%% Hard cap on a single frame, matching ?MAX_FRAME in
%% batamanta_daemon_protocol. Defined here too because the server has to
%% refuse an oversized length prefix BEFORE allocating a buffer for it.
-define(MAX_FRAME_BYTES,  64 * 1024 * 1024).

%% Path components baked at build time — used by the server to decide
%% whether to take over an existing daemon (matching hash) or refuse.
-define(CLI_MODULE_ENV,   "BATAMANTA_DAEMON_CLI_MODULE").

%% Common records and macros for the Batamanta daemon.
%%
%% Per RFC-0008-bis (batamanta-daemon-mode-spec.md):
%%
%%   * Socket path: $XDG_RUNTIME_DIR/batamanta/<app>-<version>-<target>.sock
%%     (fallback /tmp/batamanta/<app>-<version>-<target>.sock when XDG
%%      is not set, e.g. in containers or unusual environments)
%%   * Identity is `{App, Version, Target}` baked at build time. Two
%%     binaries of the same app+version+target share the same daemon;
%%     a re-deploy produces a new daemon because the version changes.
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

-define(SOCK_PATH_ENV,    "BATAMANTA_DAEMON_SOCK_PATH").
-define(PID_FILE_ENV,     "BATAMANTA_DAEMON_PID_FILE").
-define(APP_NAME_ENV,     "BATAMANTA_DAEMON_APP_NAME").
-define(APP_VERSION_ENV,  "BATAMANTA_DAEMON_APP_VERSION").
-define(TARGET_ENV,       "BATAMANTA_DAEMON_TARGET").
-define(USER_APP_ENV,     "BATAMANTA_DAEMON_USER_APP").
-define(TIMEOUT_ENV,      "BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS").
-define(TTL_ENV,          "BATAMANTA_DAEMON_DEFAULT_TTL_MS").
-define(BUILD_HASH_ENV,   "BATAMANTA_DAEMON_BUILD_HASH").

%% Path components baked at build time — used by the server to decide
%% whether to take over an existing daemon (matching hash) or refuse.
-define(CLI_MODULE_ENV,   "BATAMANTA_DAEMON_CLI_MODULE").

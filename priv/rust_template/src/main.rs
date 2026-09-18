use anyhow::{bail, Context, Result};
// nix is Unix-only (see Cargo.toml target-gated deps). Windows uses
// std::process::Command + bash instead of fork/execvp.
#[cfg(unix)]
use nix::{
    sys::wait::waitpid,
    unistd::{execvp, fork, ForkResult},
};
#[cfg(unix)]
use serde_json::json;
use std::{
    env,
    fs,
    path::{Path, PathBuf},
    process::ExitCode,
};
// CString + Unix ext traits only exist where the daemon/fork path does.
#[cfg(unix)]
use std::{
    ffi::CString,
    io::{Read, Write},
    os::unix::{ffi::OsStrExt, fs::PermissionsExt, net::UnixStream},
    time::{Duration, Instant},
};

// GENERATED_APP_NAME, GENERATED_APP_VERSION, GENERATED_TARGET and the
// BEAM daemon mode constants come from build.rs (which reads the
// BATAMANTA_* env vars set by `Batamanta.RustTemplate.compile_rust`).
// See rfcs/0008-beam-alive-mode.md and batamanta-daemon-mode-spec.md.
include!(concat!(env!("OUT_DIR"), "/generated_config.rs"));

/// Maximum time we wait when trying to connect to an existing daemon
/// before falling back to the bootstrap path.
#[cfg(unix)]
const DAEMON_CONNECT_TIMEOUT: Duration = Duration::from_millis(100);

/// Maximum time we wait for a freshly-bootstrapped daemon to bind its
/// socket before giving up.
#[cfg(unix)]
const DAEMON_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(30);

/// Maximum time we wait for the daemon to write its PID file.
#[cfg(unix)]
const DAEMON_PIDFILE_TIMEOUT: Duration = Duration::from_secs(5);

/// 24h cap, consistent with `Batamanta.DaemonConfig.validate!/1`.
const TTL_MAX_MS: u64 = 86_400_000;

// ============================================================================
// Path derivation
// ============================================================================

/// Directory where the daemon's runtime files live (Unix-only: daemon
/// mode uses AF_UNIX sockets, unsupported on Windows).
#[cfg(unix)]
fn runtime_dir() -> PathBuf {
    let base = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(env::temp_dir);
    base.join("batamanta")
}

/// Path of the AF_UNIX socket the daemon listens on.
#[cfg(unix)]
fn daemon_sock_path() -> PathBuf {
    runtime_dir().join(format!(
        "{}-{}-{}.sock",
        GENERATED_APP_NAME, GENERATED_APP_VERSION, GENERATED_TARGET
    ))
}

/// Path of the daemon's PID file.
#[cfg(unix)]
fn daemon_pid_path() -> PathBuf {
    runtime_dir().join(format!(
        "{}-{}-{}.pid",
        GENERATED_APP_NAME, GENERATED_APP_VERSION, GENERATED_TARGET
    ))
}

/// Path of the embedded `<app>.run` script (same per-binary extraction dir
/// the legacy wrapper used — kept identical so payloads stay compatible).
fn legacy_run_script_path(extract_dir: &Path) -> PathBuf {
    extract_dir
        .join("release")
        .join("bin")
        .join(format!("{}.run", GENERATED_APP_NAME))
}

// ============================================================================
// Env var interpretation
// ============================================================================

/// Why we're not in daemon mode (for diagnostics + log lines).
#[derive(Debug)]
#[allow(dead_code)] // fields are only surfaced via {:?} in the stderr warning
enum NoDaemonReason {
    FeatureDisabled,
    EnvUnset,
    EnvZero,
    EnvInvalid(String),
    TtlOutOfRange(u64),
    /// Daemon mode needs AF_UNIX sockets + fork/exec: Unix-only.
    UnsupportedOs,
}

/// Outcome of `resolve_dispatch`: either take the daemon path or fall back
/// to legacy single-shot. `Legacy(reason)` carries diagnostics so the
/// wrapper can warn to stderr if the user thought they enabled daemon
/// mode but it didn't actually fire.
enum DispatchDecision {
    Daemon,
    Legacy(NoDaemonReason),
}

#[allow(unreachable_code)]
fn resolve_dispatch() -> DispatchDecision {
    if !GENERATED_DAEMON_ENABLED {
        return DispatchDecision::Legacy(NoDaemonReason::FeatureDisabled);
    }

    // Daemon mode needs AF_UNIX sockets + fork/exec: Unix-only. Fall back
    // to legacy single-shot on Windows (with a stderr warning below).
    #[cfg(windows)]
    return DispatchDecision::Legacy(NoDaemonReason::UnsupportedOs);

    let raw = env::var(GENERATED_DAEMON_VAR).unwrap_or_default();
    let trimmed = raw.trim();

    if trimmed.is_empty() {
        // Env var unset/empty → consult the baked default.
        if GENERATED_DAEMON_DEFAULT_MS > 0 {
            DispatchDecision::Daemon
        } else {
            DispatchDecision::Legacy(NoDaemonReason::EnvUnset)
        }
    } else if trimmed == "0" {
        DispatchDecision::Legacy(NoDaemonReason::EnvZero)
    } else {
        match trimmed.parse::<u64>() {
            Ok(0) => DispatchDecision::Legacy(NoDaemonReason::EnvZero),
            Ok(ms) if ms > TTL_MAX_MS => DispatchDecision::Legacy(NoDaemonReason::TtlOutOfRange(ms)),
            Ok(_) => DispatchDecision::Daemon,
            Err(_) => DispatchDecision::Legacy(NoDaemonReason::EnvInvalid(raw.clone())),
        }
    }
}

// ============================================================================
// Payload extraction
// ============================================================================

fn extract_dir_from_payload() -> PathBuf {
    env::temp_dir().join(format!("batamanta-{}-{}-{}", GENERATED_APP_NAME, GENERATED_APP_VERSION, GENERATED_TARGET))
}

fn extract_payload_if_needed(extract_dir: &Path, bytes: &[u8]) -> Result<()> {
    if extract_dir.exists() {
        return Ok(());
    }
    fs::create_dir_all(extract_dir).context("failed to create extraction dir")?;
    let cursor = std::io::Cursor::new(bytes);
    let decoder = zstd::stream::read::Decoder::new(cursor).context("invalid zstd payload")?;
    let mut archive = tar::Archive::new(std::io::BufReader::new(decoder));
    archive.unpack(extract_dir).context("failed to unpack payload")?;
    Ok(())
}

// ============================================================================
// Daemon IPC
// ============================================================================

/// Frame format: 4-byte big-endian length prefix + JSON payload.
#[cfg(unix)]
fn write_framed<W: Write>(w: &mut W, payload: &[u8]) -> std::io::Result<()> {
    let len = payload.len() as u32;
    w.write_all(&len.to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()
}

/// Read exactly one 4-byte-prefixed frame.
#[cfg(unix)]
fn read_framed<R: Read>(r: &mut R) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf).context("short read on length prefix")?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > 64 * 1024 * 1024 {
        bail!("response frame too large: {} bytes", len);
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).context("short read on payload")?;
    Ok(buf)
}

#[derive(Debug)]
#[cfg(unix)]
struct DispatchResult {
    exit_code: i32,
}

/// Try to dispatch the user's request over an already-connected socket.
/// Returns the daemon's exit_code on success. Caller propagates it as the
/// wrapper's own exit code.
#[cfg(unix)]
fn dispatch_over_socket(mut sock: UnixStream, args: &[String]) -> Result<DispatchResult> {
    sock.set_read_timeout(Some(Duration::from_secs(120)))
        .context("set_read_timeout")?;
    sock.set_write_timeout(Some(Duration::from_secs(10)))
        .context("set_write_timeout")?;

    let cwd = env::current_dir().ok().and_then(|p| {
        p.to_str().map(|s| s.to_owned())
    });

    let env_map: serde_json::Map<String, serde_json::Value> = env::vars()
        .filter(|(k, _)| !k.starts_with("BATAMANTA_")) // skip our own bootstrap vars
        .map(|(k, v)| (k, serde_json::Value::String(v)))
        .collect();

    let payload = json!({
        "cmd": "req",
        "args": args,
        "env": env_map,
        "cwd": cwd,
        "stdin_b64": "",
        "build_hash": GENERATED_DAEMON_BUILD_HASH,
    })
    .to_string();

    write_framed(&mut sock, payload.as_bytes()).context("write request")?;

    let resp_bytes = read_framed(&mut sock).context("read response")?;
    let resp: serde_json::Value = serde_json::from_slice(&resp_bytes)
        .context("decode response JSON")?;

    // Protocol-level error from the daemon (e.g. hash_mismatch, no_cli_main
    // when user_app is unset, ...). Surface the reason so the caller can
    // decide whether to retry (hash_mismatch → cold start) or fall back.
    if let Some(false) = resp.get("ok").and_then(|v| v.as_bool()) {
        let reason = resp
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        return Err(anyhow::anyhow!("daemon rejected request: {}", reason));
    }

    let exit_code = resp
        .get("exit_code")
        .and_then(|v| v.as_i64())
        .unwrap_or(1);

    if let Some(stdout_b64) = resp.get("stdout_b64").and_then(|v| v.as_str()) {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(stdout_b64)
            .context("decode stdout_b64")?;
        std::io::stdout().write_all(&bytes)?;
    }
    if let Some(stderr_b64) = resp.get("stderr_b64").and_then(|v| v.as_str()) {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(stderr_b64)
            .context("decode stderr_b64")?;
        std::io::stderr().write_all(&bytes)?;
    }

    Ok(DispatchResult {
        exit_code: exit_code as i32,
    })
}

/// Connect to a daemon socket with a hard timeout. Returns Ok(stream) on
/// success, Err on any failure (no socket, ECONNREFUSED, timeout, etc.).
#[cfg(unix)]
fn try_connect(sock_path: &Path, timeout: Duration) -> Result<UnixStream> {
    let started = Instant::now();
    let mut last_err = None;
    while started.elapsed() < timeout {
        match UnixStream::connect(sock_path) {
            Ok(s) => return Ok(s),
            Err(e) => {
                last_err = Some(e);
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
    match last_err {
        Some(e) => Err(anyhow::anyhow!("connect timeout after {:?}: {}", timeout, e)),
        None => Err(anyhow::anyhow!("connect timeout after {:?}", timeout)),
    }
}

/// Liveness check: read the PID file, send `kill(pid, 0)`. Returns true
/// only if the process exists and we have permission to signal it.
#[cfg(unix)]
fn daemon_is_alive(pid_path: &Path) -> bool {
    let pid_str = match fs::read_to_string(pid_path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let pid: i32 = match pid_str.trim().parse() {
        Ok(n) => n,
        Err(_) => return false,
    };
    // SAFETY: `kill(pid, 0)` is a standard idiom to liveness-check; it
    // doesn't actually send a signal but errors if the process is gone.
    let rc = unsafe { libc::kill(pid, 0) };
    if rc == 0 {
        true
    } else {
        let err = std::io::Error::last_os_error();
        // ESRCH = process gone; EPERM = exists but not ours (we treat as
        // alive to avoid killing a foreign PID — but practically the
        // daemon-mode permission setup means this can't happen on the
        // same UID).
        err.raw_os_error() != Some(libc::ESRCH)
    }
}

/// Poll for the appearance of `path` until it exists or `timeout` elapses.
#[cfg(unix)]
fn wait_for_path(path: &Path, timeout: Duration) -> bool {
    let started = Instant::now();
    while started.elapsed() < timeout {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    path.exists()
}

/// Spawn the daemon BEAM in the background and wait for it to bind the
/// socket + write its PID file. The child process gets all the env vars
/// the daemon needs; it runs `<app>.run batamanta_daemon_bootstrap` which
/// is the run-script mode that loads only the daemon app and parks.
#[cfg(unix)]
fn bootstrap_daemon(extract_dir: &Path) -> Result<()> {
    let sock_path = daemon_sock_path();
    let pid_path = daemon_pid_path();

    // Pre-clean any stale files (defensive — usually the connect attempt
    // already determined there was no live daemon, but a sock file may
    // be left over from a killed BEAM).
    let _ = fs::remove_file(&sock_path);
    let _ = fs::remove_file(&pid_path);
    if let Some(parent) = sock_path.parent() {
        fs::create_dir_all(parent).context("create runtime dir")?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .context("chmod runtime dir")?;
    }

    let run_script = legacy_run_script_path(extract_dir);
    if !run_script.exists() {
        bail!("run script missing at {}", run_script.display());
    }

    let run_script_cstr = CString::new(run_script.as_os_str().as_encoded_bytes())
        .context("invalid run script path")?;
    let bootstrap_arg = CString::new("batamanta_daemon_bootstrap").unwrap();

    // Build argv for the child: <run-script> batamanta_daemon_bootstrap
    let argv = vec![run_script_cstr.clone(), bootstrap_arg];

    // SAFETY: `fork` is async-signal-safe and we don't touch shared state
    // between fork and exec.
    let child_pid = match unsafe { fork() } {
        Ok(ForkResult::Parent { child }) => child,
        Ok(ForkResult::Child) => {
            // Child: set daemon env vars and exec the bootstrap.
            set_daemon_env_for_bootstrap(&sock_path, &pid_path);
            let _ = execvp(&run_script_cstr, &argv);
            // If we get here, execvp failed.
            eprintln!(
                "batamanta: failed to execvp daemon bootstrap: {}",
                std::io::Error::last_os_error()
            );
            std::process::exit(1);
        }
        Err(e) => {
            bail!("fork failed: {}", e);
        }
    };

    // Parent: wait for the socket and PID file to appear.
    if !wait_for_path(&sock_path, DAEMON_BOOTSTRAP_TIMEOUT) {
        let _ = nix::sys::signal::kill(child_pid, nix::sys::signal::Signal::SIGKILL);
        let _ = waitpid(child_pid, None);
        bail!(
            "daemon did not bind socket within {:?}",
            DAEMON_BOOTSTRAP_TIMEOUT
        );
    }
    if !wait_for_path(&pid_path, DAEMON_PIDFILE_TIMEOUT) {
        let _ = nix::sys::signal::kill(child_pid, nix::sys::signal::Signal::SIGKILL);
        let _ = waitpid(child_pid, None);
        bail!(
            "daemon did not write pid file within {:?}",
            DAEMON_PIDFILE_TIMEOUT
        );
    }

    // The child continues to run in the background; we don't reap it
    // because we want it to outlive the wrapper. It will be reparented
    // to init when the wrapper exits.
    let _ = child_pid;
    Ok(())
}

#[cfg(unix)]
fn set_daemon_env_for_bootstrap(sock_path: &Path, pid_path: &Path) {
    // Called from the freshly-forked child between fork() and execvp().
    // Strictly speaking, `std::env::set_var` is not async-signal-safe, but
    // it's fine here because we're not in a signal handler — we're in
    // ordinary single-threaded child code before exec. The pre-exec
    // window is also too short to race with other threads in practice.
    let sock_str = sock_path.to_string_lossy().into_owned();
    let pid_str = pid_path.to_string_lossy().into_owned();
    std::env::set_var("BATAMANTA_DAEMON_SOCK_PATH", &sock_str);
    std::env::set_var("BATAMANTA_DAEMON_PID_FILE", &pid_str);
    std::env::set_var("BATAMANTA_DAEMON_BUILD_HASH", GENERATED_DAEMON_BUILD_HASH);
    std::env::set_var("BATAMANTA_DAEMON_USER_APP", GENERATED_DAEMON_USER_APP);
    std::env::set_var(
        "BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS",
        GENERATED_DAEMON_REQUEST_TIMEOUT_MS.to_string(),
    );
    if !GENERATED_DAEMON_CLI_MODULE.is_empty() {
        std::env::set_var("BATAMANTA_DAEMON_CLI_MODULE", GENERATED_DAEMON_CLI_MODULE);
    }
}

// ============================================================================
// Daemon dispatch (orchestrator)
// ============================================================================

/// Unix daemon dispatch (AF_UNIX socket + fork/exec bootstrap).
#[cfg(unix)]
fn dispatch_via_daemon(args: &[String]) -> Result<i32> {
    let sock_path = daemon_sock_path();
    let pid_path = daemon_pid_path();
    let extract_dir = extract_dir_from_payload();

    // Pre-extract payload if necessary (the daemon's bootstrap path also
    // extracts, but the warm path here might be invoked without a prior
    // bootstrap in this exact run, so extract defensively).
    let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
    extract_payload_if_needed(&extract_dir, bytes)?;

    // Try warm path: socket + live PID. Loop at most twice: once for
    // the happy case, once if the first connect succeeds but the daemon
    // reports a hash mismatch (in which case it shuts itself down and
    // we need to cold-start a fresh one with our current hash).
    for attempt in 0..2 {
        let live = sock_path.exists() && daemon_is_alive(&pid_path);
        if !live {
            // Cold start (or re-start after the previous daemon quit).
            bootstrap_daemon(&extract_dir)?;
        }

        let sock = match try_connect(&sock_path, DAEMON_CONNECT_TIMEOUT) {
            Ok(s) => s,
            Err(e) => {
                if attempt == 0 {
                    // Could be a stale sock file from a killed BEAM —
                    // fall through to bootstrap which clears it.
                    continue;
                }
                return Err(e.context(format!(
                    "connecting to daemon at {}",
                    sock_path.display()
                )));
            }
        };

        match dispatch_over_socket(sock, args) {
            Ok(result) => return Ok(result.exit_code),
            Err(e) => {
                let msg = format!("{:#}", e);
                if attempt == 0 && msg.contains("hash_mismatch") {
                    eprintln!(
                        "batamanta: daemon is stale (hash mismatch); respawning"
                    );
                    // Give the dying daemon a moment to release the
                    // socket; otherwise bootstrap's pre-clean of the
                    // sock file races with the dying process.
                    std::thread::sleep(Duration::from_millis(100));
                    let _ = fs::remove_file(&sock_path);
                    let _ = fs::remove_file(&pid_path);
                    continue;
                }
                return Err(e);
            }
        }
    }

    // Loop ran out (shouldn't happen, but the compiler needs an exit).
    Err(anyhow::anyhow!("daemon dispatch gave up after 2 attempts"))
}

// ============================================================================
// Legacy path
// ============================================================================

#[cfg(unix)]
fn build_argv_for(program: &Path, args: &[String]) -> Result<Vec<CString>> {
    let program_cstr = CString::new(program.as_os_str().as_encoded_bytes())
        .context("invalid program path")?;
    let mut argv = vec![program_cstr];
    for arg in args {
        argv.push(CString::new(arg.as_bytes()).context("invalid arg")?);
    }
    Ok(argv)
}

// Convert a Windows path to MSYS2/Git-Bash style so bash can find the
// executable on PATH. Passing `C:/...` doesn't work (bash won't translate
// it back); drive letters must become `/c/...`. Restored verbatim from the
// pre-daemon wrapper.
#[cfg(windows)]
fn to_msys2_path(p: &str) -> String {
    let s = p;
    // Strip the Windows extended-length prefix \\?\ if present.
    let s = s.strip_prefix(r"\\?\").unwrap_or(s);
    // Convert drive letter "C:\" or "C:/" to "/c/".
    let s = if let Some(rest) = s.strip_prefix(|c: char| c.is_ascii_alphabetic()) {
        if let Some(after_colon) = rest.strip_prefix(':') {
            // Drive-letter path: "C:\foo" or "C:/foo" -> "/c/foo"
            let drive = s.chars().next().unwrap().to_ascii_lowercase();
            format!("/{}{}", drive, after_colon.replace('\\', "/"))
        } else {
            s.to_string()
        }
    } else {
        s.to_string()
    };
    s
}

/// Windows legacy path: the .run script in the payload is a POSIX shell
/// script and Windows can't execute it directly. Shell out to bash.exe
/// (provided by Git for Windows, already a build prereq) and wait for the
/// child.
///
/// The whole chain boots EXCLUSIVELY from the bundled ERTS inside the
/// payload (.run → bin/<app> → releases/elixir → erts erl.exe — the
/// packager patches ERL_EXEC to the PE launcher at build time). System
/// Erlang is never consulted: no PATH probing, no BATAMANTA_ERL, no
/// ERL_BINDIR override.
#[cfg(windows)]
fn exec_legacy(run_script: &Path, _args: &[String]) -> Result<ExitCode> {
    let bash = locate_bash_exe()?;

    // Build a small bash wrapper:
    //   1. Clean POSIX PATH with just Git usr/bin (readlink, dirname, pwd
    //      for the .run script). Deliberately NOT passing through the
    //      parent's `;`-separated $PATH (corrupts bash's parser).
    //   2. BATAMANTA_RUN_SCRIPT so the .run script finds itself (we
    //      `source` it, so $0 is "bash").
    //   3. BATAMANTA_USER_ARGS round-trip for multi-word CLI args.
    //   4. `source` the original .run script verbatim.
    let script_posix = to_msys2_path(&run_script.to_string_lossy());
    let mut script = String::new();
    script.push_str("set -e\n");
    script.push_str(&format!("export BATAMANTA_RUN_SCRIPT=\"{script_posix}\"\n"));

    // Serialize the user's CLI args into BATAMANTA_USER_ARGS (single-quoted,
    // `'` escaped as `'\''`) so multi-word args survive the
    // `bash -c` -> `source` -> `exec` chain. No-op on POSIX (execvp path).
    let user_args_str: String = env::args_os()
        .skip(1)
        .map(|a| {
            let s = a.to_string_lossy();
            let escaped = s.replace('\'', "'\\''");
            format!("'{escaped}'")
        })
        .collect::<Vec<_>>()
        .join(" ");
    script.push_str(&format!(
        "export BATAMANTA_USER_ARGS=\"{user_args_str}\"\n"
    ));

    // Minimal POSIX PATH: Git usr/bin only. The sourced .run script
    // prepends the payload's own erts bin dir itself. Never pass through
    // the parent's `;`-separated $PATH (breaks bash's parser).
    if let Some(tools_bin) = git_tools_bin(&bash) {
        let tools_bin_posix = to_msys2_path(&tools_bin.to_string_lossy());
        script.push_str(&format!("export PATH=\"{tools_bin_posix}\"\n"));
    } else {
        eprintln!("[batamanta] WARNING: could not find Git usr/bin for dirname/readlink/pwd; .run script may fail");
    }
    script.push_str("export ERL_FLAGS=\"\" ERL_AFLAGS=\"\" ERL_ZFLAGS=\"\"\n");
    script.push_str(&format!("source \"{script_posix}\"\n"));

    let mut cmd = std::process::Command::new(&bash);
    // `bash -c "script" -- args...`: the `--` keeps the first user arg out
    // of $0 (else it gets eaten and the .run script mis-shifts $@).
    cmd.arg("-c").arg(&script).arg("--");
    for arg in env::args_os().skip(1) {
        cmd.arg(arg);
    }

    let status = cmd
        .status()
        .context("Failed to spawn bash for .run script")?;
    let code = status.code().unwrap_or(1) as u8;
    Ok(ExitCode::from(code))
}

// Locate bash.exe: BATAMANTA_BASH override, then current PATH, then the
// conventional Git for Windows install dirs.
#[cfg(windows)]
fn locate_bash_exe() -> Result<String> {
    if let Ok(p) = std::env::var("BATAMANTA_BASH") {
        if std::path::Path::new(&p).exists() {
            return Ok(p);
        }
    }

    let candidates = [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\usr\bin\bash.exe",
    ];
    for c in candidates {
        if std::path::Path::new(c).exists() {
            return Ok(c.to_string());
        }
    }

    anyhow::bail!(
        "Could not find bash.exe. Install Git for Windows (scoop install git) \
         or set BATAMANTA_BASH to the full path of bash.exe."
    )
}

// Given bash.exe, find Git for Windows' companion `usr\bin` (dirname,
// readlink, pwd...). The sourced .run script needs these tools.
#[cfg(windows)]
fn git_tools_bin(bash_path: &str) -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(bash_path);
    let dir = p.parent()?;
    let dir_str = dir.to_string_lossy();

    // .../Git/bin/bash.exe -> .../Git/usr/bin
    if dir_str.ends_with("Git\\bin") || dir_str.ends_with("Git/bin") {
        let candidate = dir.parent()?.join("usr").join("bin");
        if candidate.join("dirname.exe").exists() {
            return Some(candidate);
        }
    }
    // .../Git/usr/bin/bash.exe -> right here
    if dir_str.ends_with("Git\\usr\\bin") || dir_str.ends_with("Git/usr/bin") {
        if dir.join("dirname.exe").exists() {
            return Some(dir.to_path_buf());
        }
    }
    // .../Git/mingw64/bin/bash.exe -> .../Git/usr/bin
    if dir_str.ends_with("Git\\mingw64\\bin") || dir_str.ends_with("Git/mingw64/bin") {
        let candidate = dir.parent()?.parent()?.join("usr").join("bin");
        if candidate.join("dirname.exe").exists() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(unix)]
fn exec_legacy(run_script: &Path, args: &[String]) -> Result<()> {
    let argv = build_argv_for(run_script, args)?;
    let program = &argv[0];
    // SAFETY: execvp replaces the process image; nothing after it runs
    // on success.
    let _ = unsafe { execvp(program, &argv) };
    Err(anyhow::anyhow!(
        "execvp failed: {}",
        std::io::Error::last_os_error()
    ))
}

// ============================================================================
// main
// ============================================================================

fn main() -> Result<ExitCode> {
    let args: Vec<String> = env::args().skip(1).collect();

    match resolve_dispatch() {
        // Daemon mode needs AF_UNIX sockets + fork/exec: Unix-only. On
        // Windows resolve_dispatch never yields Daemon (UnsupportedOs).
        #[cfg(unix)]
        DispatchDecision::Daemon => {
            let extract_dir = extract_dir_from_payload();
            let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
            extract_payload_if_needed(&extract_dir, bytes)?;

            let run_script = legacy_run_script_path(&extract_dir);
            if !run_script.exists() {
                bail!(
                    ".run script not found at {}. Expected GENERATED_APP_NAME={}",
                    run_script.display(),
                    GENERATED_APP_NAME
                );
            }

            match dispatch_via_daemon(&args) {
                Ok(code) => Ok(ExitCode::from(code as u8)),
                Err(e) => {
                    eprintln!(
                        "batamanta: daemon dispatch failed ({}); falling back to legacy",
                        e
                    );
                    exec_legacy(&run_script, &args)?;
                    Ok(ExitCode::from(1))
                }
            }
        }
        DispatchDecision::Legacy(reason) => {
            // Legacy single-shot. Still need to extract the payload and
            // exec the <app>.run script.
            let extract_dir = extract_dir_from_payload();
            let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
            extract_payload_if_needed(&extract_dir, bytes)?;

            let run_script = legacy_run_script_path(&extract_dir);
            if !run_script.exists() {
                bail!(
                    ".run script not found at {}. Expected GENERATED_APP_NAME={}",
                    run_script.display(),
                    GENERATED_APP_NAME
                );
            }

            // If the user thought they enabled daemon mode but the
            // decision is Legacy, warn to stderr so misconfigurations
            // surface immediately.
            if matches!(
                reason,
                NoDaemonReason::EnvUnset
                    | NoDaemonReason::EnvInvalid(_)
                    | NoDaemonReason::TtlOutOfRange(_)
                    | NoDaemonReason::EnvZero
                    | NoDaemonReason::UnsupportedOs
            ) {
                eprintln!(
                    "batamanta: daemon mode requested ({:?}); running legacy single-shot",
                    reason
                );
            }

            // Unix execvp never returns; Windows returns the child's code.
            #[cfg(unix)]
            {
                exec_legacy(&run_script, &args)?;
                Ok(ExitCode::from(1))
            }
            #[cfg(windows)]
            {
                exec_legacy(&run_script, &args)
            }
        }
        // Unreachable on Windows (resolve_dispatch never yields Daemon
        // there); keeps the match exhaustive under cfg.
        #[cfg(windows)]
        _ => unreachable!("daemon mode is Unix-only"),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn daemon_sock_path_is_namespaced() {
        let path = daemon_sock_path();
        let path_str = path.to_string_lossy();
        assert!(path_str.contains(GENERATED_APP_NAME));
        assert!(path_str.contains(GENERATED_APP_VERSION));
        assert!(path_str.contains(GENERATED_TARGET));
        assert!(path_str.ends_with(".sock"));
    }

    #[test]
    #[cfg(unix)]
    fn daemon_pid_path_matches_sock_path_dir() {
        let sock = daemon_sock_path();
        let pid = daemon_pid_path();
        assert_eq!(sock.parent(), pid.parent());
    }

    #[test]
    #[cfg(unix)]
    fn frame_roundtrip() {
        let payload = b"hello world";
        let mut buf: Vec<u8> = Vec::new();
        write_framed(&mut buf, payload).unwrap();
        let mut slice = buf.as_slice();
        let decoded = read_framed(&mut slice).unwrap();
        assert_eq!(decoded, payload);
    }

    #[test]
    #[cfg(unix)]
    fn frame_rejects_oversize() {
        // Construct a fake "header" declaring 100 MiB, then verify we
        // bail before trying to allocate.
        let huge_len: u32 = 100 * 1024 * 1024;
        let buf = huge_len.to_be_bytes().to_vec();
        let mut slice = buf.as_slice();
        let result = read_framed(&mut slice);
        assert!(result.is_err(), "should reject oversized frame");
    }

    #[test]
    fn resolve_dispatch_legacy_when_disabled() {
        // We can't toggle GENERATED_DAEMON_ENABLED at runtime — it's a
        // compile-time constant — but we can verify the function returns
        // Daemon when the constant is true (which the smoke test build
        // does) and Legacy otherwise.
        if GENERATED_DAEMON_ENABLED {
            // When enabled and env var unset, we should either Daemon
            // (default_ms > 0) or Legacy (default_ms == 0). Both are
            // valid outcomes based on build-time config.
            assert!(matches!(
                resolve_dispatch(),
                DispatchDecision::Daemon | DispatchDecision::Legacy(NoDaemonReason::EnvUnset)
            ));
        } else {
            assert!(matches!(
                resolve_dispatch(),
                DispatchDecision::Legacy(NoDaemonReason::FeatureDisabled)
            ));
        }
    }
}

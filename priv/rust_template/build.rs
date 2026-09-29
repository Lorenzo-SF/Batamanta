use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let app_name = env::var("BATAMANTA_APP_NAME").unwrap_or_else(|_| "app".to_string());
    let app_version = env::var("BATAMANTA_APP_VERSION").unwrap_or_else(|_| "0.0.0".to_string());
    let target = env::var("BATAMANTA_TARGET").unwrap_or_else(|_| "unknown".to_string());

    // T-008-bis: BEAM daemon mode config baked at build time. The wrapper
    // Rust uses these constants at runtime to decide between legacy
    // single-shot execution and daemon mode (persistent BEAM across
    // invocations). Source: DaemonConfig.to_env_vars/1 in
    // lib/batamanta/daemon_config.ex.
    let daemon_enabled_raw =
        env::var("BATAMANTA_BEAM_ALIVE_ENABLED").unwrap_or_else(|_| "0".to_string());
    let daemon_enabled_bool = daemon_enabled_raw == "1";

    let daemon_var =
        env::var("BATAMANTA_BEAM_ALIVE_VAR").unwrap_or_else(|_| "BATAMANTA_BEAM_ALIVE".to_string());

    let daemon_default_ms_raw =
        env::var("BATAMANTA_BEAM_ALIVE_DEFAULT_MS").unwrap_or_else(|_| "0".to_string());
    let daemon_default_ms: u64 = daemon_default_ms_raw.parse().unwrap_or(0);

    let daemon_user_app =
        env::var("BATAMANTA_DAEMON_USER_APP").unwrap_or_else(|_| "".to_string());

    let daemon_request_timeout_raw =
        env::var("BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS").unwrap_or_else(|_| "60000".to_string());
    let daemon_request_timeout_ms: u64 = daemon_request_timeout_raw.parse().unwrap_or(60000);

    let daemon_cli_module =
        env::var("BATAMANTA_DAEMON_CLI_MODULE").unwrap_or_else(|_| "".to_string());

    let daemon_build_hash =
        env::var("BATAMANTA_DAEMON_BUILD_HASH").unwrap_or_else(|_| "".to_string());

    // Subcommands that must bypass the daemon and run in the foreground.
    // A warm daemon buffers output and has no stdin, so animated
    // spinners, prompts, pagers and key-driven TUIs cannot work through
    // it. Comma-separated; empty means "nothing declared".
    let daemon_foreground =
        env::var("BATAMANTA_DAEMON_FOREGROUND").unwrap_or_else(|_| "".to_string());

    // Full compatibility tuple for the daemon, computed by
    // `Batamanta.Daemon.identity/1` (app, version, target, format,
    // exec_mode, erts, cli_module) plus the short digest
    // `Batamanta.Daemon.runtime_basename/1` derives the socket and PID
    // filenames from. Two binaries may share a daemon only when these
    // match; the ERTS version in particular used to be missing, so two
    // builds of the same app differing only in their bundled ERTS
    // fought over one socket and evicted each other on every alternate
    // invocation.
    let daemon_identity =
        env::var("BATAMANTA_DAEMON_IDENTITY").unwrap_or_else(|_| "".to_string());
    let daemon_basename =
        env::var("BATAMANTA_DAEMON_BASENAME").unwrap_or_else(|_| "".to_string());

    let out_dir = env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("generated_config.rs");

    // These land inside Rust string literals. App names and versions are
    // project-controlled but not necessarily quote-free (a version like
    // `1.0.0-rc"1"` would otherwise emit a file that fails to compile
    // with a confusing "unterminated string" error pointing at build.rs).
    let q = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");

    let app_name = q(&app_name);
    let app_version = q(&app_version);
    let target = q(&target);
    let daemon_var = q(&daemon_var);
    let daemon_user_app = q(&daemon_user_app);
    let daemon_cli_module = q(&daemon_cli_module);
    let daemon_build_hash = q(&daemon_build_hash);
    let daemon_identity = q(&daemon_identity);
    let daemon_basename = q(&daemon_basename);
    let daemon_foreground = q(&daemon_foreground);

    fs::write(
        &dest_path,
        format!(
            "// Generated at compile time
pub const GENERATED_APP_NAME: &str = \"{app_name}\";
pub const GENERATED_APP_VERSION: &str = \"{app_version}\";
pub const GENERATED_TARGET: &str = \"{target}\";
pub const GENERATED_DAEMON_ENABLED: bool = {daemon_enabled_bool};
pub const GENERATED_DAEMON_VAR: &str = \"{daemon_var}\";
pub const GENERATED_DAEMON_DEFAULT_MS: u64 = {daemon_default_ms};
pub const GENERATED_DAEMON_USER_APP: &str = \"{daemon_user_app}\";
pub const GENERATED_DAEMON_REQUEST_TIMEOUT_MS: u64 = {daemon_request_timeout_ms};
pub const GENERATED_DAEMON_CLI_MODULE: &str = \"{daemon_cli_module}\";
pub const GENERATED_DAEMON_BUILD_HASH: &str = \"{daemon_build_hash}\";
pub const GENERATED_DAEMON_IDENTITY: &str = \"{daemon_identity}\";
pub const GENERATED_DAEMON_BASENAME: &str = \"{daemon_basename}\";
pub const GENERATED_DAEMON_FOREGROUND: &str = \"{daemon_foreground}\";
",
        ),
    )
    .unwrap();

    // Copy payload from src/ to OUT_DIR/ so include_bytes! can find it at compile time
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let src_payload = Path::new(&manifest_dir).join("src/payload.tar.zst");
    let dest_payload = Path::new(&out_dir).join("payload.tar.zst");

    if src_payload.exists() {
        fs::copy(&src_payload, &dest_payload)
            .expect("Failed to copy payload to OUT_DIR");
    } else {
        panic!(
            "Payload not found at {}. \
             Batamanta must copy the compressed payload to src/ before Cargo builds.",
            src_payload.display()
        );
    }

    println!("cargo:rustc-env=BATAMANTA_APP_NAME={}", app_name);
}

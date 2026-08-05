use anyhow::{Context, Result};
use indicatif::{ProgressBar, ProgressStyle};
#[cfg(unix)]
use nix::unistd::execvp;
use std::{
    env,
    fs,
    io::BufReader,
    process::ExitCode,
};
#[cfg(unix)]
use std::{ffi::CString, os::unix::ffi::OsStrExt};
use tar::Archive;
use zstd::stream::read::Decoder as ZstdDecoder;

// GENERATED_APP_NAME comes from build.rs
include!(concat!(env!("OUT_DIR"), "/generated_config.rs"));

fn main() -> Result<ExitCode> {
    let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
    // Deterministic dir from payload prefix — no hash crate needed
    let prefix: String = bytes[..8.min(bytes.len())]
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect();
    let extract_dir = env::temp_dir().join(format!("batamanta_{}_{}", GENERATED_APP_NAME, prefix));

    // Extract payload on first run — deterministic path enables reuse
    if !extract_dir.exists() {
        let spinner = ProgressBar::new_spinner();
        spinner.set_style(
            ProgressStyle::default_spinner()
                .template("{spinner:.green} {msg}")
                .unwrap(),
        );
        spinner.set_message("Extracting payload...");

        fs::create_dir_all(&extract_dir).context("Failed to create temp dir")?;
        let cursor = std::io::Cursor::new(bytes);
        let decoder = ZstdDecoder::new(cursor).context("Invalid zstd payload")?;
        let mut archive = Archive::new(BufReader::new(decoder));
        archive
            .unpack(&extract_dir)
            .context("Failed to unpack payload")?;

        spinner.finish_and_clear();
    }

    // Build path to the .run script
    let run_script = extract_dir
        .join("release")
        .join("bin")
        .join(format!("{}.run", GENERATED_APP_NAME));

    if !run_script.exists() {
        anyhow::bail!(
            ".run script not found at {}. \
             Expected GENERATED_APP_NAME={}",
            run_script.display(),
            GENERATED_APP_NAME
        );
    }

    run_target(&run_script)
}

// Replace this process with the .run script on Unix (execvp), or shell out
// to bash + the .run script on Windows. The .run script handles PATH,
// BINDIR, neutralization, and exec mode routing (cli/daemon/tui).
#[cfg(unix)]
fn run_target(run_script: &std::path::Path) -> Result<ExitCode> {
    let program_cstr =
        CString::new(run_script.as_os_str().as_bytes()).context("Invalid run script path")?;
    let mut args: Vec<CString> = vec![program_cstr.clone()];
    for arg in env::args_os().skip(1) {
        args.push(CString::new(arg.as_bytes()).context("Invalid arg")?);
    }

    // execvp only returns on failure
    let _ = execvp(&program_cstr, &args);
    Err(anyhow::anyhow!(
        "execvp failed: {}",
        std::io::Error::last_os_error()
    ))
}

// Windows fallback: the .run script in the payload is a POSIX shell script
// and Windows can't execute it directly. Shell out to bash.exe (provided by
// Git for Windows, which is already a build prereq) and wait for the child.
//
// The .run script internally calls `erl.exe` from the payload's erts-X.Y.Z/bin
// directory. That `erl.exe` is *not* a standalone executable — it's the
// shim used by the upstream NSIS installer and crashes (0xC0000005) when
// invoked outside the installer's context. To work around this, we don't
// invoke the .run script directly. Instead we synthesize a small bash
// script that overrides PATH to point at the system Erlang (or whatever
// `BATAMANTA_ERL` points at) and reuses the same neutralization + PATH
// setup the .run script does. This way the app boots against a working
// `erl.exe` while still loading the .beam files from the payload's
// `erts-X.Y.Z/lib/` and the project's own `releases/`.
#[cfg(windows)]
fn run_target(run_script: &std::path::Path) -> Result<ExitCode> {
    let bash = std::env::var("BATAMANTA_BASH")
        .unwrap_or_else(|_| "bash.exe".to_string());

    // Find a working `erl.exe` to inject into PATH. Prefer the env var so
    // the user can pin a specific install; otherwise scan %PROGRAMFILES%
    // for an Erlang/OTP install (Erlang is conventionally at
    // `C:\Program Files\erl-<vsn>\bin\erl.exe`).
    let system_erl_bin = locate_system_erl_bin()?;

    // Build a small bash wrapper that:
    //   1. Prepends the system erl bin dir to PATH (so `erl`, `escript` resolve)
    //   2. Sets BINDIR/ERL_ROOTDIR to the system erl
    //   3. Neutralizes asdf/mise/kerl
    //   4. `source`s the original .run script (which is POSIX shell), then
    //      execs the escript with the args
    //
    // The .run script does `exec bin/<app> "$@"`. After sourcing, those
    // shell vars are in scope, so PATH and BINDIR point at the system erl
    // and the escript starts cleanly.
    let erl_bin_posix = system_erl_bin.replace('\\', "/");
    let script_posix = run_script.to_string_lossy().replace('\\', "/");
    let mut script = String::new();
    script.push_str("set -e\n");
    script.push_str(&format!("export PATH=\"{erl_bin_posix}:$PATH\"\n"));
    script.push_str(&format!("export BINDIR=\"{erl_bin_posix}\"\n"));
    script.push_str(&format!("export ERL_ROOTDIR=\"{erl_bin_posix}/..\"\n"));
    script.push_str("export ERL_FLAGS=\"\" ERL_AFLAGS=\"\" ERL_ZFLAGS=\"\"\n");
    // The .run script does `exec bin/<app> "$@"` — by overriding PATH above
    // and leaving BINDIR set, that exec picks up our system erl. We don't
    // need to translate the script at all, just source it.
    script.push_str(&format!("source \"{script_posix}\"\n"));

    let mut cmd = std::process::Command::new(&bash);
    cmd.arg("-c").arg(&script);
    for arg in env::args_os().skip(1) {
        cmd.arg(arg);
    }

    let status = cmd
        .status()
        .context("Failed to spawn bash for .run script")?;
    let code = status.code().unwrap_or(1) as u8;
    Ok(ExitCode::from(code))
}

// Walk a few conventional Erlang install locations and return the first that
// contains an `erl.exe`. `BATAMANTA_ERL` overrides everything; otherwise we
// look under %PROGRAMFILES% and the Cargo build's compile-time PATH.
#[cfg(windows)]
fn locate_system_erl_bin() -> Result<String> {
    if let Ok(p) = std::env::var("BATAMANTA_ERL") {
        let exe = std::path::Path::new(&p).join("erl.exe");
        if exe.exists() {
            return Ok(p);
        }
    }

    // Walk %PROGRAMFILES% for any erl-*/bin/erl.exe. On Windows installs
    // Erlang always lives at `C:\Program Files\erl-<vsn>`.
    if let Ok(pf) = std::env::var("ProgramFiles") {
        if let Ok(entries) = std::fs::read_dir(&pf) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with("erl-") {
                    let bin = entry.path().join("bin");
                    if bin.join("erl.exe").exists() {
                        return Ok(bin.to_string_lossy().to_string());
                    }
                }
            }
        }
    }
    if let Ok(pf86) = std::env::var("ProgramFiles(x86)") {
        if let Ok(entries) = std::fs::read_dir(&pf86) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with("erl-") {
                    let bin = entry.path().join("bin");
                    if bin.join("erl.exe").exists() {
                        return Ok(bin.to_string_lossy().to_string());
                    }
                }
            }
        }
    }

    anyhow::bail!(
        "Could not find a system Erlang/OTP install. Set BATAMANTA_ERL \
         to the bin\\ directory of an Erlang install, or install Erlang \
         (e.g. via `scoop install erlang`)."
    )
}

// ============================================================================
// TESTS
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    #[test]
    fn test_get_app_name_is_compiled() {
        let app = GENERATED_APP_NAME;
        assert!(!app.is_empty());
    }

    #[test]
    fn test_payload_exists() {
        let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
        assert!(bytes.len() > 100, "Payload seems too small");
    }
}

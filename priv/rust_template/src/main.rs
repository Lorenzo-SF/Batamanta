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

// Convert a Windows path to MSYS2/Git-Bash style so bash can find the
// executable on PATH. The simple `replace('\\', "/")` is not enough:
// bash on Windows uses `/c/Program Files/...` (or `/cygdrive/c/...` for
// Cygwin) — passing `C:/Program Files/...` results in `which` returning
// nothing because bash doesn't translate that form back to the
// underlying Windows path.
//
// This converts:
//   C:\foo\bar           -> /c/foo/bar
//   C:\Program Files\..  -> /c/Program Files/..
//   \\?\C:\foo           -> /c/foo  (extended-length prefix stripped)
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
    let bash = locate_bash_exe()?;

    // Find a working `erl.exe` to inject into PATH. Prefer the env var so
    // the user can pin a specific install; otherwise scan %PROGRAMFILES%
    // for an Erlang/OTP install (Erlang is conventionally at
    // `C:\Program Files\erl-<vsn>\bin\erl.exe`).
    let system_erl_bin = locate_system_erl_bin()?;

    // Build a small bash wrapper that:
    //   1. Builds PATH from scratch using POSIX `:` separators (mixing
    //      Windows `;` separators breaks the bash PATH parser; on
    //      Windows the Rust std::env::join_paths uses `;` which would
    //      corrupt $PATH if it ends up inside the bash script)
    //   2. Sets ERL_BINDIR/BINDIR/ERL_ROOTDIR to the system erl
    //   3. Neutralizes asdf/mise/kerl
    //   4. Sets BATAMANTA_RUN_SCRIPT so the .run script can find itself
    //      (we `source` it, so $0 is "bash" and the classic readlink
    //      trick can't recover the real path)
    //   5. `source`s the original .run script (which is POSIX shell), then
    //      execs the escript with the args
    //
    // The .run script does `exec bin/<app> "$@"`. After sourcing, those
    // shell vars are in scope, so PATH and BINDIR point at the system erl
    // and the escript starts cleanly.
    //
    // ERL_BINDIR is the new env var the .run script reads. When
    // ERL_BINDIR is set the .run script uses it as BINDIR instead of
    // computing its own from the payload's erts-X.Y.Z/bin, which on
    // Windows is the NSIS installer shim that crashes (0xC0000005)
    // when invoked outside the installer.
    //
    // CRITICAL: paths passed to bash on Windows must use MSYS2's
    // `/c/Program Files/...` form, NOT `C:/Program Files/...` (which
    // looks the same but bash's command lookup doesn't translate it
    // back to the Windows path — `which` returns nothing). The simple
    // backslash→slash replace is NOT enough; we need to convert the
    // drive letter too. to_msys2_path() does that.
    let erl_bin_posix = to_msys2_path(&system_erl_bin);
    let script_posix = to_msys2_path(&run_script.to_string_lossy());
    let mut script = String::new();
    script.push_str("set -e\n");
    script.push_str(&format!("export BATAMANTA_RUN_SCRIPT=\"{script_posix}\"\n"));

    // Serialize the user's CLI args into a single env var the .run script
    // can re-parse via `eval "set -- $BATAMANTA_USER_ARGS"`. This is the
    // workaround for multi-word args being mangled somewhere in the
    // `bash -c "script" -- arg1 "arg with spaces" arg3` chain on Windows
    // (the arg count seen by alaja doesn't match what the user typed).
    // Each arg is single-quoted with internal `'` escaped as `'\''` so
    // spaces, newlines, and other shell metacharacters survive the
    // round-trip. POSIX path (cfg(unix)) uses execvp directly and never
    // sets this var, so it's a no-op there.
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

    // Compose a clean POSIX PATH from the three dirs we actually need:
    //   - system erl bin (so escript, erl, erlc resolve)
    //   - Git usr/bin (so readlink, dirname, pwd resolve)
    //   - Git mingw64/bin (so other tools resolve)
    // We deliberately do NOT pass through $PATH from the parent: on
    // Windows, $PATH is `;`-separated and would corrupt the bash PATH
    // parser. The four dirs above cover everything the .run script and
    // the spawned escript need.
    let mut posix_path = format!("{erl_bin_posix}");
    if let Some(tools_bin) = git_tools_bin(&bash) {
        let tools_bin_posix = to_msys2_path(&tools_bin.to_string_lossy());
        posix_path.push(':');
        posix_path.push_str(&tools_bin_posix);
    } else {
        eprintln!("[batamanta] WARNING: could not find Git usr/bin for dirname/readlink/pwd; .run script may fail");
    }
    script.push_str(&format!("export PATH=\"{posix_path}\"\n"));
    script.push_str(&format!("export ERL_BINDIR=\"{erl_bin_posix}\"\n"));
    script.push_str(&format!("export BINDIR=\"{erl_bin_posix}\"\n"));
    script.push_str(&format!("export ERL_ROOTDIR=\"{erl_bin_posix}/..\"\n"));
    script.push_str("export ERL_FLAGS=\"\" ERL_AFLAGS=\"\" ERL_ZFLAGS=\"\"\n");
    // The .run script does `exec bin/<app> "$@"` — by setting ERL_BINDIR
    // above, the .run script will use our system erl as BINDIR and won't
    // prepend the payload's broken bin/ to PATH. We source the .run
    // verbatim; no translation needed.
    script.push_str(&format!("source \"{script_posix}\"\n"));

    let mut cmd = std::process::Command::new(&bash);
    // IMPORTANT: with `bash -c "script" arg1 arg2 ...`, bash sets $0 to
    // the first arg after the script and $@ to the REST. So if we just
    // pass the user's args, the first one gets eaten into $0 (and our
    // .run script falls into the "fallback to $0" branch). The fix is
    // the canonical `--` separator: `bash -c "script" -- arg1 arg2 ...`
    // sets $0 to `--` and $@ to (arg1, arg2, ...). The .run script
    // then receives all user args via "$@".
    cmd.arg("-c").arg(&script).arg("--");
    for arg in env::args_os().skip(1) {
        cmd.arg(arg);
    }
    // No need to set PATH via cmd.env — the script sets it itself with
    // the right (POSIX `:`) separator. Setting it from Rust would
    // re-introduce the Windows `;` separator and break bash's PATH
    // parser.

    let status = cmd
        .status()
        .context("Failed to spawn bash for .run script")?;
    let code = status.code().unwrap_or(1) as u8;
    Ok(ExitCode::from(code))
}

// Locate bash.exe. We need it to source the .run script and to do the
// POSIX-style PATH/BINDIR dance. In order:
//   1. BATAMANTA_BASH env var (explicit override)
//   2. Look on the current PATH (so scoop-installed git works)
//   3. Walk the conventional Git for Windows install dirs
#[cfg(windows)]
fn locate_bash_exe() -> Result<String> {
    if let Ok(p) = std::env::var("BATAMANTA_BASH") {
        if std::path::Path::new(&p).exists() {
            return Ok(p);
        }
    }

    // The PATH of a launched process inherits what was set at build time
    // (the Cargo run path) plus what `mix batamanta` added. But when the
    // user double-clicks the .exe or runs it from a fresh shell, PATH
    // may not have Git in it. Walk the standard install dirs.
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

// Given a path to bash.exe, walk up the directory tree to find the
// companion `usr\bin` dir that ships with Git for Windows (where
// `dirname`, `readlink`, `pwd` etc. live). The .run script we source
// uses these tools; without them, the script silently fails with
// "command not found" and the rest of the launch dies.
//
// Conventionally:
//   C:\Program Files\Git\bin\bash.exe         -> C:\Program Files\Git\usr\bin
//   C:\Program Files\Git\usr\bin\bash.exe    -> C:\Program Files\Git\usr\bin
//   C:\Program Files\Git\mingw64\bin\bash.exe (rare) -> ...\mingw64\bin
#[cfg(windows)]
fn git_tools_bin(bash_path: &str) -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(bash_path);
    let dir = p.parent()?;
    let dir_str = dir.to_string_lossy();

    // If bash is at .../Git/bin/bash.exe, tools are at .../Git/usr/bin
    if dir_str.ends_with("Git\\bin") || dir_str.ends_with("Git/bin") {
        let candidate = dir.parent()?.join("usr").join("bin");
        if candidate.join("dirname.exe").exists() {
            return Some(candidate);
        }
    }
    // If bash is at .../Git/usr/bin/bash.exe, tools are right there
    if dir_str.ends_with("Git\\usr\\bin") || dir_str.ends_with("Git/usr/bin") {
        if dir.join("dirname.exe").exists() {
            return Some(dir.to_path_buf());
        }
    }
    // If bash is at .../Git/mingw64/bin/bash.exe, tools are at .../Git/usr/bin
    if dir_str.ends_with("Git\\mingw64\\bin") || dir_str.ends_with("Git/mingw64/bin") {
        let candidate = dir.parent()?.parent()?.join("usr").join("bin");
        if candidate.join("dirname.exe").exists() {
            return Some(candidate);
        }
    }
    None
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

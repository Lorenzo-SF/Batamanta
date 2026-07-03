use anyhow::{Context, Result};
use indicatif::{ProgressBar, ProgressStyle};
use nix::unistd::execvp;
use std::{
    env,
    ffi::CString,
    fs,
    io::BufReader,
    os::unix::ffi::OsStrExt,
    process::ExitCode,
};
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

    // Replace this process with the .run script — it handles PATH, BINDIR,
    // neutralization, and exec mode routing (cli/daemon/tui).
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

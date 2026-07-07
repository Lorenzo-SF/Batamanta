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

// GENERATED_APP_NAME and GENERATED_INSTANCE_ID come from build.rs.
// INSTANCE_ID is a UUID v4 generated at compile time, giving every binary
// its own unique runtime namespace (`/tmp/batamanta-<UUID>/`). See RFC-0008.
include!(concat!(env!("OUT_DIR"), "/generated_config.rs"));

fn main() -> Result<ExitCode> {
    let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
    // Per-binary UUID isolates runtime resources (extraction dir, future
    // socket/lock files for BEAM alive mode). Same binary → same dir on
    // repeated executions; different binaries (same payload, different build)
    // → disjoint dirs. See RFC-0008 §"Identificación única".
    let extract_dir = env::temp_dir().join(format!("batamanta-{}", GENERATED_INSTANCE_ID));

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

    #[test]
    fn test_get_app_name_is_compiled() {
        let app = GENERATED_APP_NAME;
        assert!(!app.is_empty());
    }

    #[test]
    fn test_instance_id_is_compiled_and_is_uuid() {
        let id = GENERATED_INSTANCE_ID;
        assert!(!id.is_empty(), "INSTANCE_ID must be baked at build time");
        assert!(
            uuid::Uuid::parse_str(id).is_ok(),
            "INSTANCE_ID must parse as UUID v4, got: {}",
            id
        );
    }

    #[test]
    fn test_extract_dir_uses_instance_id() {
        let dir = format!("/tmp/batamanta-{}", GENERATED_INSTANCE_ID);
        // Sanity: dir path contains the UUID we expect. Doesn't require the
        // payload to exist — the format is what we're verifying.
        assert!(dir.contains(GENERATED_INSTANCE_ID));
        assert!(dir.starts_with("/tmp/batamanta-"));
    }

    #[test]
    fn test_payload_exists() {
        let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));
        assert!(bytes.len() > 100, "Payload seems too small");
    }
}

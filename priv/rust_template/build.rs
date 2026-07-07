use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let app_name = env::var("BATAMANTA_APP_NAME").unwrap_or_else(|_| "app".to_string());

    // T-008: per-binary UUID v4 — runtime resources (`/tmp/batamanta-<UUID>/`)
    // never collide between binaries that share payload content.
    let instance_id = uuid::Uuid::new_v4().to_string();

    // T-008: BEAM alive mode config baked at build time. The wrapper Rust
    // uses these constants at runtime to decide between legacy single-shot
    // execution and alive mode (persistent BEAM across invocations).
    // Source: KeeperConfig.to_env_vars/1 in lib/batamanta/keeper_config.ex.
    let beam_alive_enabled_raw =
        env::var("BATAMANTA_BEAM_ALIVE_ENABLED").unwrap_or_else(|_| "0".to_string());
    let beam_alive_enabled_bool = beam_alive_enabled_raw == "1";

    let beam_alive_var =
        env::var("BATAMANTA_BEAM_ALIVE_VAR").unwrap_or_else(|_| "BATAMANTA_BEAM_ALIVE".to_string());

    let beam_alive_default_ms_raw =
        env::var("BATAMANTA_BEAM_ALIVE_DEFAULT_MS").unwrap_or_else(|_| "0".to_string());
    let beam_alive_default_ms: u64 = beam_alive_default_ms_raw.parse().unwrap_or(0);

    let out_dir = env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("generated_config.rs");

    fs::write(
        &dest_path,
        format!(
            "// Generated at compile time
pub const GENERATED_APP_NAME: &str = \"{app_name}\";
pub const GENERATED_INSTANCE_ID: &str = \"{instance_id}\";
pub const GENERATED_BEAM_ALIVE_ENABLED: bool = {beam_alive_enabled_bool};
pub const GENERATED_BEAM_ALIVE_VAR: &str = \"{beam_alive_var}\";
pub const GENERATED_BEAM_ALIVE_DEFAULT_MS: u64 = {beam_alive_default_ms};
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

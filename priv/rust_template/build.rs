use std::fs;
use std::path::Path;

fn main() {
    let app_name = std::env::var("BATAMANTA_APP_NAME").unwrap_or_else(|_| "app".to_string());

    // Write config to a generated file
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("generated_config.rs");

    fs::write(
        &dest_path,
        format!(
            "// Generated at compile time
pub const GENERATED_APP_NAME: &str = \"{}\";
",
            app_name
        ),
    )
    .unwrap();

    // Copy payload from src/ to OUT_DIR/ so include_bytes! can find it at compile time
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
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

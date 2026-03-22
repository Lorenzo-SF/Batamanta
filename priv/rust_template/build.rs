use std::fs;
use std::path::Path;

fn main() {
    let exec_mode = std::env::var("BATAMANTA_EXEC_MODE").unwrap_or_else(|_| "cli".to_string());
    let app_name = std::env::var("BATAMANTA_APP_NAME").unwrap_or_else(|_| "app".to_string());
    let format = std::env::var("BATAMANTA_FORMAT").unwrap_or_else(|_| "release".to_string());

    // Write config to a generated file
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("generated_config.rs");

    fs::write(
        &dest_path,
        format!(
            "// Generated at compile time
pub const GENERATED_EXEC_MODE: &str = \"{}\";
pub const GENERATED_APP_NAME: &str = \"{}\";
pub const GENERATED_FORMAT: &str = \"{}\";
",
            exec_mode, app_name, format
        ),
    )
    .unwrap();

    println!("cargo:rustc-env=BATAMANTA_EXEC_MODE={}", exec_mode);
    println!("cargo:rustc-env=BATAMANTA_APP_NAME={}", app_name);
    println!("cargo:rustc-env=BATAMANTA_FORMAT={}", format);
}

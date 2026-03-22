fn main() {
    // Embeber variables de entorno en el binario en tiempo de compilación
    // Estas se usan en runtime pero se configuran durante el build de Elixir/Mix

    let exec_mode = std::env::var("BATAMANTA_EXEC_MODE").unwrap_or_else(|_| "cli".to_string());
    println!("cargo:rustc-env=BATAMANTA_EXEC_MODE={}", exec_mode);

    let app_name = std::env::var("BATAMANTA_APP_NAME").unwrap_or_else(|_| "app".to_string());
    println!("cargo:rustc-env=BATAMANTA_APP_NAME={}", app_name);

    let format = std::env::var("BATAMANTA_FORMAT").unwrap_or_else(|_| "release".to_string());
    println!("cargo:rustc-env=BATAMANTA_FORMAT={}", format);
}

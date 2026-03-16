use anyhow::{Context, Result};
use indicatif::{ProgressBar, ProgressStyle};
use std::{
    env, fs,
    io::BufReader,
    path::{Path, PathBuf},
    process::{Command, ExitCode, Stdio},
    sync::atomic::{AtomicBool, Ordering},
};
use tar::Archive;
use zstd::stream::read::Decoder as ZstdDecoder;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

static TERMINAL_RESTORED: AtomicBool = AtomicBool::new(false);

/// Restaura la terminal a un estado seguro al salir
fn restore_terminal() {
    if !TERMINAL_RESTORED.swap(true, Ordering::SeqCst) {
        #[cfg(unix)]
        {
            let _ = Command::new("stty")
                .arg("sane")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .output();
        }
    }
}

fn get_exec_mode() -> String {
    env::var("BATAMANTA_EXEC_MODE").unwrap_or_else(|_| "cli".to_string())
}

fn get_app_name() -> String {
    env::var("BATAMANTA_APP_NAME").unwrap_or_else(|_| "app".to_string())
}

struct TempDirGuard {
    path: PathBuf,
    cleanup: bool,
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        if get_exec_mode() != "daemon" {
            restore_terminal();
        }

        if self.cleanup && self.path.exists() {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn main() -> Result<ExitCode> {
    let bytes = include_bytes!("payload.tar.zst");
    let hash = format!("{:x}", md5::compute(bytes));

    let mut temp_path = env::temp_dir();
    temp_path.push(format!("batamanta_{}", hash));

    let cleanup = env::var("BATAMANTA_CLEANUP").unwrap_or_else(|_| "0".to_string()) == "1";
    let mut _guard = TempDirGuard {
        path: temp_path.clone(),
        cleanup,
    };

    let exec_mode = get_exec_mode();

    // 🔴 FIX: Si es daemon, JAMÁS borramos la carpeta porque Erlang vive en background
    if exec_mode == "daemon" {
        _guard.cleanup = false;
    }

    if !temp_path.exists() {
        if exec_mode != "daemon" {
            let spinner = ProgressBar::new_spinner();
            spinner.set_style(
                ProgressStyle::default_spinner()
                    .template("{spinner:.green} {msg}")
                    .unwrap(),
            );
            spinner.set_message("Extracting payload...");
            extract_payload(bytes, &temp_path)?;
            spinner.finish_and_clear();
        } else {
            extract_payload(bytes, &temp_path)?;
        }
    }

    let release_dir = temp_path.join("release");
    let bin_dir = release_dir.join("bin");
    let release_lib = release_dir.join("lib");
    let app_name = get_app_name();

    // 🔴 CRÍTICO: Detectar si existe el script de la aplicación
    // En Linux/macOS, Mix genera un script shell en bin/<app_name> que configura
    // TODAS las variables de entorno correctamente.
    // Pero para evitar problemas con el script, usamos erlexec directamente
    let app_script = bin_dir.join(&app_name);
    let use_app_script = false; // Forzar uso de erlexec

    let exit_code = if use_app_script {
        // ✅ USAR SCRIPT DE MIX (RECOMENDADO para Linux/macOS)
        run_with_script(&app_script, &release_dir, &release_lib, &exec_mode)?
    } else {
        // 🔴 FALLBACK: Ejecutar erlexec directamente
        run_with_erlexec(&release_dir, &bin_dir, &release_lib, &app_name, &exec_mode)?
    };

    Ok(ExitCode::from(exit_code))
}

/// Ejecuta la aplicación usando el script de Mix (bin/<app_name>)
fn run_with_script(
    app_script: &Path,
    release_dir: &Path,
    release_lib: &Path,
    exec_mode: &str,
) -> Result<u8> {
    let mut cmd = Command::new(app_script);

    // 🔴 FIX: Variables de entorno críticas para Linux
    let releases_version_dir = release_dir.join("releases").join("0.1.0");

    cmd.env("RELEASE_ROOT", release_dir)
        .env(
            "RELEASE_SYS_CONFIG",
            releases_version_dir.join("sys.config"),
        )
        .env("RELEASE_VM_ARGS", releases_version_dir.join("vm.args"))
        .env("RELEASE_PROG", get_app_name())
        .env("ERL_LIBS", release_lib)
        // 🔴 CRÍTICO: Forzar modo interactivo para evitar buffering en Linux
        // Esto hace que stdout se bufee por líneas en lugar de por bloques
        .env("ERL_AFLAGS", "-noshell");

    // Para daemon, no queremos que el script espere
    if exec_mode == "daemon" {
        cmd.env("RELEASE_BOOT_WAIT", "false");
    }

    // Añadir argumentos después de --
    cmd.arg("--").args(env::args().skip(1));

    // Configurar stdio según el modo
    if exec_mode != "daemon" {
        // ✅ CLI/TUI: Heredar stdin/stdout/stderr
        // Esto es CRÍTICO para que el output se muestre inmediatamente
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    } else {
        // 🔴 DAEMON: Redirigir todo a null
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    }

    let mut child = cmd.spawn().context("Failed to spawn application script")?;

    if exec_mode == "daemon" {
        return Ok(0);
    }

    let status = child.wait().context("Failed to wait for application")?;
    Ok(status.code().unwrap_or(0) as u8)
}

/// Ejecuta la aplicación usando erlexec directamente (fallback)
fn run_with_erlexec(
    release_dir: &Path,
    bin_dir: &Path,
    release_lib: &Path,
    app_name: &str,
    exec_mode: &str,
) -> Result<u8> {
    // Buscar erlexec en el ERTS
    let erlexec = find_file(&release_dir.join("erts"), "erlexec")
        .or_else(|| find_file(release_dir, "erlexec"))
        .context("erlexec not found")?;

    #[cfg(unix)]
    {
        if let Ok(metadata) = fs::metadata(&erlexec) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o755);
            let _ = fs::set_permissions(&erlexec, perms);
        }
    }

    let bin_path = erlexec.parent().unwrap();

    // Buscar el archivo .boot - primero intentar start.boot, luego cualquier otro
    let releases_dir = release_dir.join("releases").join("0.1.0");
    let boot_path = releases_dir.join("start.boot");
    let boot_path = if boot_path.exists() {
        boot_path
    } else {
        find_file_by_ext(&release_dir.join("releases"), "boot")
            .or_else(|| find_file_by_ext(bin_dir, "boot"))
            .context("No .boot file found")?
    };

    let boot_arg = boot_path.with_extension("").to_string_lossy().into_owned();
    let releases_version_dir = release_dir.join("releases").join("0.1.0");

    let mut cmd = Command::new(&erlexec);

    // 🔴 FIX: Variables de entorno CORRECTAS para Linux y macOS
    cmd.env("ROOTDIR", release_dir)
        .env("BINDIR", bin_path)
        .env("ERL_LIBS", release_lib)
        .env("RELEASE_ROOT", release_dir)
        .env("RELEASE_PROG", app_name)
        .env(
            "RELEASE_SYS_CONFIG",
            releases_version_dir.join("sys.config"),
        )
        .env("RELEASE_VM_ARGS", releases_version_dir.join("vm.args"))
        .env("EMU", "beam")
        .env("PROGNAME", "erl")
        // Boot variables
        .arg("-boot")
        .arg(&boot_arg)
        .arg("-boot_var")
        .arg("RELEASE_LIB")
        .arg(release_lib)
        .arg("-boot_var")
        .arg("RELEASE_ROOT")
        .arg(release_dir)
        // 🔴 FIX: Desactivar EPMD para evitar cuelgues en Linux
        .arg("-start_epmd")
        .arg("false")
        .arg("-noshell");

    // 🔴 CRÍTICO: Forzar flushing de stdout en Linux
    // Añadir flag -extra para pasar argumentos a la aplicación
    cmd.arg("-extra").arg("--").args(env::args().skip(1));

    // Configurar stdio según el modo
    if exec_mode == "daemon" {
        // 🔴 DAEMON: Usar -detached y redirigir output
        cmd.arg("-detached")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    } else {
        // ✅ CLI/TUI: Heredar stdin/stdout/stderr
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    }

    let mut child = cmd.spawn().context("Failed to spawn Erlang VM process")?;

    if exec_mode == "daemon" {
        return Ok(0);
    }

    let status = child.wait().context("Failed to wait for Erlang process")?;

    restore_terminal();

    Ok(status.code().unwrap_or(0) as u8)
}

fn extract_payload(bytes: &[u8], path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    let cursor = std::io::Cursor::new(bytes);
    let decoder = ZstdDecoder::new(cursor).context("Invalid compression")?;
    let mut archive = Archive::new(BufReader::new(decoder));
    archive.unpack(path).context("Unpack failed")?;
    Ok(())
}

fn find_file(path: &Path, name: &str) -> Option<PathBuf> {
    if path.is_dir() {
        for entry in fs::read_dir(path).ok()? {
            let entry = entry.ok()?;
            let p = entry.path();
            if p.is_dir() {
                if let Some(found) = find_file(&p, name) {
                    return Some(found);
                }
            } else if p.file_name().and_then(|s| s.to_str()) == Some(name) {
                return Some(p);
            }
        }
    }
    None
}

fn find_file_by_ext(path: &Path, ext: &str) -> Option<PathBuf> {
    if path.is_dir() {
        for entry in fs::read_dir(path).ok()? {
            let entry = entry.ok()?;
            let p = entry.path();
            if p.is_dir() {
                if let Some(found) = find_file_by_ext(&p, ext) {
                    return Some(found);
                }
            } else if p.extension().and_then(|s| s.to_str()) == Some(ext) {
                return Some(p);
            }
        }
    }
    None
}

// ============================================================================
// TESTS
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;

    #[test]
    fn test_get_exec_mode_defaults_to_cli() {
        env::remove_var("BATAMANTA_EXEC_MODE");
        assert_eq!(get_exec_mode(), "cli");
    }

    #[test]
    fn test_get_exec_mode_reads_env_variable() {
        env::set_var("BATAMANTA_EXEC_MODE", "daemon");
        assert_eq!(get_exec_mode(), "daemon");
        env::remove_var("BATAMANTA_EXEC_MODE");
    }

    #[test]
    fn test_get_app_name_defaults_to_app() {
        // Asegurar que la variable no está setada
        env::remove_var("BATAMANTA_APP_NAME");
        let result = get_app_name();
        // Limpiar después del test
        env::remove_var("BATAMANTA_APP_NAME");
        assert_eq!(result, "app");
    }

    #[test]
    fn test_get_app_name_reads_env_variable() {
        env::set_var("BATAMANTA_APP_NAME", "test_app_name");
        let result = get_app_name();
        env::remove_var("BATAMANTA_APP_NAME");
        assert_eq!(result, "test_app_name");
    }

    #[test]
    fn test_find_file_finds_file_in_flat_directory() {
        let temp_dir = tempfile::tempdir().unwrap();
        let file_path = temp_dir.path().join("test.txt");
        File::create(&file_path).unwrap();

        let result = find_file(temp_dir.path(), "test.txt");
        assert!(result.is_some());
        assert_eq!(result.unwrap(), file_path);
    }

    #[test]
    fn test_find_file_finds_file_in_nested_directory() {
        let temp_dir = tempfile::tempdir().unwrap();
        let subdir = temp_dir.path().join("subdir");
        fs::create_dir(&subdir).unwrap();
        let file_path = subdir.join("erlexec");
        File::create(&file_path).unwrap();

        let result = find_file(temp_dir.path(), "erlexec");
        assert!(result.is_some());
        assert_eq!(result.unwrap(), file_path);
    }

    #[test]
    fn test_find_file_returns_none_when_not_found() {
        let temp_dir = tempfile::tempdir().unwrap();
        let result = find_file(temp_dir.path(), "nonexistent");
        assert!(result.is_none());
    }

    #[test]
    fn test_find_file_by_ext_finds_file_with_extension() {
        let temp_dir = tempfile::tempdir().unwrap();
        let file_path = temp_dir.path().join("test.boot");
        File::create(&file_path).unwrap();

        let result = find_file_by_ext(temp_dir.path(), "boot");
        assert!(result.is_some());
        assert_eq!(result.unwrap(), file_path);
    }

    #[test]
    fn test_find_file_by_ext_returns_none_when_not_found() {
        let temp_dir = tempfile::tempdir().unwrap();
        let result = find_file_by_ext(temp_dir.path(), "boot");
        assert!(result.is_none());
    }
}

use anyhow::{anyhow, Context, Result};
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

/// Spawns a process detached from terminal (portable: works on Linux and macOS)
/// Returns immediately in parent, child continues running independently.
///
/// `env` contains additional/override env vars that are merged with the parent's
/// environment. This is critical: execve replaces the environment entirely,
/// so we must pass the full merged environment.
#[cfg(unix)]
fn spawn_detached(program: &str, args: &[&str], env: &[(&str, &str)]) -> Result<()> {
    unsafe {
        let pid = libc::fork();
        if pid < 0 {
            return Err(anyhow!("fork failed"));
        }
        if pid > 0 {
            // Parent: give child time to start and return
            std::thread::sleep(std::time::Duration::from_millis(500));
            return Ok(());
        }
        // Child: create new session (detaches from terminal)
        libc::setsid();
        // Close stdin, redirect stdout/stderr to /dev/null IF needed
        libc::close(0);
        libc::open("/dev/null\0".as_ptr() as *const libc::c_char, libc::O_RDWR);
        // We let stdout and stderr connected to current terminal so testing/logs output correctly.
        // If we strictly dup2 to /dev/null, everything printed directly to shell is silenced.

        // Build full environment: inherit parent env + merge additional vars
        let mut full_env: std::collections::HashMap<String, String> = std::env::vars().collect();
        for (k, v) in env {
            full_env.insert(k.to_string(), v.to_string());
        }

        let env_cstrings: Vec<std::ffi::CString> = full_env
            .iter()
            .map(|(k, v)| std::ffi::CString::new(format!("{}={}", k, v)).unwrap())
            .collect();
        let mut env_ptrs: Vec<*const libc::c_char> = env_cstrings
            .iter()
            .map(|s| s.as_ptr())
            .collect();
        env_ptrs.push(std::ptr::null()); // null-terminate

        // Build argv: argv[0] must be program name (POSIX requirement)
        let program_cstr = std::ffi::CString::new(program).unwrap();
        let arg_cstrings: Vec<std::ffi::CString> = args
            .iter()
            .map(|s| std::ffi::CString::new(*s).unwrap())
            .collect();
        let mut arg_ptrs: Vec<*const libc::c_char> = Vec::with_capacity(args.len() + 2);
        arg_ptrs.push(program_cstr.as_ptr()); // argv[0] = program
        for cs in &arg_cstrings {
            arg_ptrs.push(cs.as_ptr());
        }
        arg_ptrs.push(std::ptr::null()); // null-terminate

        libc::execve(
            program_cstr.as_ptr(),
            arg_ptrs.as_ptr(),
            env_ptrs.as_ptr(),
        );
        // If execve returns, it failed
        libc::_exit(1);
    }
}

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

// Include generated config from build.rs
include!(concat!(env!("OUT_DIR"), "/generated_config.rs"));

fn get_exec_mode() -> String {
    GENERATED_EXEC_MODE.to_string()
}

fn get_app_name() -> String {
    GENERATED_APP_NAME.to_string()
}

fn get_format() -> String {
    GENERATED_FORMAT.to_string()
}

/// Obtiene la versión del release leyendo start_erl.data
/// Este archivo contiene la versión de ERTS y la versión del release
fn get_release_version(release_dir: &Path) -> String {
    let start_erl_path = release_dir.join("releases").join("start_erl.data");

    if let Ok(content) = fs::read_to_string(&start_erl_path) {
        // El archivo tiene formato: "ERTS_VERSION RELEASE_VERSION"
        // ej: "16.0 1.0.0"
        let parts: Vec<&str> = content.trim().split_whitespace().collect();
        if parts.len() >= 2 {
            return parts[1].to_string();
        }
    }

    // Fallback: buscar el directorio de release más reciente
    let releases_dir = release_dir.join("releases");
    if let Ok(entries) = fs::read_dir(&releases_dir) {
        let mut versions: Vec<String> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
            .filter(|s| !s.starts_with('.') && s != "COOKIE")
            .collect();

        versions.sort();
        if let Some(latest) = versions.into_iter().last() {
            return latest;
        }
    }

    // Último fallback
    "0.1.0".to_string()
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
    let format = get_format();

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

    // Ejecutar según el formato
    let exit_code = if format == "escript" {
        // ✅ Modo escript: ejecutar el escript directamente
        run_escript(&release_dir, &app_name, &exec_mode)?
    } else {
        // 🔴 Modo release: usar erlexec con boot scripts
        run_with_erlexec(&release_dir, &bin_dir, &release_lib, &app_name, &exec_mode)?
    };

    Ok(ExitCode::from(exit_code))
}

/// Ejecuta un escript (formato escript)
///
/// Los escripts de Elixir/Mix son binarios autocontenidos que:
///
/// 1. Tienen un shebang que apunta a erlexec
/// 2. Contienen el código de la aplicación embebido
/// 3. Necesitan un ERTS mínimo para ejecutarse
///
/// Estructura esperada del payload escript:
/// ```
/// temp_dir/
/// ├── bin/
/// │   └── <app_name>     # El escript compilado (ejecutable)
/// └── erts/
///     ├── bin/
///     │   ├── erlexec    # Intérprete de escripts
///     │   ├── erl
///     │   └── beam.smp
///     └── lib/
///         └── (librerías mínimas)
/// ```
fn run_escript(release_dir: &Path, app_name: &str, exec_mode: &str) -> Result<u8> {
    // Para escripts, la estructura es diferente a releases:
    // - El escript está en bin/<app_name>
    // - El erts está en erts/ (no bin/erts/)
    let bin_dir = release_dir.join("bin");
    let erts_dir = release_dir.join("erts");

    // Buscar el escript (debe existir en bin/)
    let escript_path = bin_dir.join(app_name);
    if !escript_path.exists() {
        return Err(anyhow!("Escript not found: {:?}", escript_path));
    }

    // Hacer el escript ejecutable en Unix
    #[cfg(unix)]
    {
        if let Ok(metadata) = fs::metadata(&escript_path) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o755);
            let _ = fs::set_permissions(&escript_path, perms);
        }
    }

    // Buscar erlexec para configurar variables de entorno
    // erlexec está en erts-X.Y/bin/ dentro del ERTS cache
    let erlexec = find_file(&erts_dir, "erlexec")
        .or_else(|| find_file(&erts_dir.join("bin"), "erlexec"))
        .context("erlexec not found in erts")?;

    // Note: erl_bin is kept for potential future use but not needed currently
    let _erl_bin = find_file(&erts_dir.join("bin"), "erl").or_else(|| find_file(&erts_dir, "erl"));

    let erts_bin_dir = erlexec
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| erts_dir.join("bin"));

    // Crear un script de wrapper que configure el entorno y ejecute el escript
    #[cfg(unix)]
    {
        let wrapper_script =
            create_escript_wrapper(&escript_path, &erts_dir, &erts_bin_dir, app_name, exec_mode)?;
        let wrapper_script_str = wrapper_script.to_string_lossy().into_owned();

        let mut cmd = if exec_mode == "daemon" {
            // Usar spawn_detached para crear una nueva sesión (portable: Linux y macOS)
            let mut all_args: Vec<String> = vec![wrapper_script_str.clone(), "-daemon".to_string()];
            all_args.extend(env::args().skip(1));
            let args: Vec<&str> = all_args.iter().map(|s| s.as_str()).collect();
            let bindir_str = erts_bin_dir.to_string_lossy().into_owned();
            let erl_libs_str = erts_dir.join("lib").to_string_lossy().into_owned();
            let rootdir_str = escript_path
                .parent()
                .unwrap()
                .to_string_lossy()
                .into_owned();
            let env: Vec<(&str, &str)> = vec![
                ("BINDIR", &bindir_str),
                ("ERL_LIBS", &erl_libs_str),
                ("ROOTDIR", &rootdir_str),
                ("EMULATOR", "beam"),
            ];
            spawn_detached(&wrapper_script_str, &args, &env)?;
            return Ok(0);
        } else {
            let mut c = Command::new(&wrapper_script_str);
            c.stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit());
            c
        };

        // Pasar argumentos de usuario
        cmd.args(env::args().skip(1));

        let mut child = cmd.spawn().context("Failed to spawn escript process")?;

        if exec_mode == "daemon" {
            // En modo daemon, esperamos un poco para asegurar que arranc
            std::thread::sleep(std::time::Duration::from_millis(500));

            // Verificar que el proceso sigue vivo
            match child.try_wait() {
                Ok(Some(_status)) => {
                    return Err(anyhow!("Daemon process exited prematurely"));
                }
                Ok(None) => Ok(0),
                Err(e) => {
                    return Err(anyhow!("Error checking daemon status: {}", e));
                }
            }
        } else {
            let status = child.wait().context("Failed to wait for escript process")?;
            restore_terminal();
            Ok(status.code().unwrap_or(0) as u8)
        }
    }

    #[cfg(not(unix))]
    {
        // En Windows, ejecutar directamente con erlexec
        let mut cmd = Command::new(&erlexec);
        cmd.arg(&escript_path)
            .args(env::args().skip(1))
            .env("BINDIR", &erts_bin_dir)
            .env("EMULATOR", "beam");

        if exec_mode == "daemon" {
            cmd.arg("-detached")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
        } else {
            cmd.stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit());
        }

        let mut child = cmd.spawn().context("Failed to spawn escript process")?;

        if exec_mode == "daemon" {
            return Ok(0);
        }

        let status = child.wait().context("Failed to wait for escript process")?;
        Ok(status.code().unwrap_or(0) as u8)
    }
}

/// Crea un wrapper script para ejecutar el escript con el entorno correcto
#[cfg(unix)]
#[allow(dead_code)]
fn create_escript_wrapper(
    escript_path: &Path,
    erts_dir: &Path,
    erts_bin_dir: &Path,
    app_name: &str,
    exec_mode: &str,
) -> Result<PathBuf> {
    use std::io::Write;

    let wrapper_path =
        env::temp_dir().join(format!("batamanta_escript_wrapper_{}", std::process::id()));

    // El escript ya tiene el shebang, solo necesitamos configurar el PATH y vars
    let erts_lib_dir = erts_dir.join("lib");

    // Determinar si es modo daemon basado en si setsid nos pasó el flag
    let daemon_flag = if exec_mode == "daemon" { "-daemon" } else { "" };

    let wrapper_content = format!(
        r#"#!/bin/sh
# Batamanta escript wrapper
# Generated automatically

BINDIR="{bindir}"
ERL_ROOTDIR="{erts_dir}"
ERL_LIBS="{erts_lib_dir}"
PROGNAME="{app_name}"

# Configurar PATH para que erl/beam sean encontrables
export PATH="$BINDIR:$PATH"

# Variables de entorno para el escript
export ROOTDIR="$ERL_ROOTDIR"
export BINDIR="$BINDIR"
export ERL_LIBS="$ERL_LIBS"
export EMULATOR="beam"
export PROGNAME="$PROGNAME"
export RELEASE_ROOT="$ERL_ROOTDIR"

# Filtrar el flag -daemon de los argumentos si está presente
# (lo añade setsid, no el usuario)
args=""
for arg in "$@"; do
    if [ "$arg" != "-daemon" ]; then
        args="$args $arg"
    fi
done

# Ejecutar el escript con -noshell si es modo daemon
if [ -n "{daemon_flag}" ]; then
    # Ejecutar con -noshell para que erl no intente abrir una terminal
    exec "{escript}" -noshell $args
else
    exec "{escript}" $args
fi
"#,
        bindir = erts_bin_dir.display(),
        erts_dir = erts_dir.display(),
        erts_lib_dir = erts_lib_dir.display(),
        app_name = app_name,
        escript = escript_path.display(),
        daemon_flag = daemon_flag
    );

    let mut file = fs::File::create(&wrapper_path)?;
    file.write_all(wrapper_content.as_bytes())?;

    // Hacer ejecutable
    let mut perms = fs::metadata(&wrapper_path)?.permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&wrapper_path, perms)?;

    Ok(wrapper_path)
}

/// Ejecuta un release de OTP usando erlexec con boot scripts
///
/// Esta función es para el modo "release" tradicional de Elixir/OTP.
/// Requiere:
/// - bin/<app_name> - script de inicio (wrapper de erlexec)
/// - releases/<version>/start.boot - script de boot
/// - releases/<version>/sys.config - configuración del sistema
/// - lib/ - librerías de la aplicación
/// - erts-<version>/ - Erlang Runtime System
fn run_with_erlexec(
    release_dir: &Path,
    bin_dir: &Path,
    release_lib: &Path,
    app_name: &str,
    exec_mode: &str,
) -> Result<u8> {
    // Buscar erlexec
    let erlexec = find_file(bin_dir, "erlexec")
        .or_else(|| find_file(release_dir, "erlexec"))
        .context("erlexec not found")?;

    // Asegurar que erlexec es ejecutable
    #[cfg(unix)]
    {
        if let Ok(metadata) = fs::metadata(&erlexec) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o755);
            let _ = fs::set_permissions(&erlexec, perms);
        }
    }

    let bin_path = erlexec.parent().unwrap();

    // Detectar dinámicamente la versión del release
    let release_version = get_release_version(release_dir);
    let releases_version_dir = release_dir.join("releases").join(&release_version);

    // Buscar el archivo .boot
    let boot_path = releases_version_dir.join("start.boot");
    let boot_path = if boot_path.exists() {
        boot_path
    } else {
        find_file_by_ext(&release_dir.join("releases"), "boot")
            .or_else(|| find_file_by_ext(bin_dir, "boot"))
            .context("No .boot file found")?
    };

    let boot_arg = boot_path.with_extension("").to_string_lossy().into_owned();

    // Construir argumentos
    let mut args: Vec<String> = vec![
        "-boot".to_string(),
        boot_arg.clone(),
        "-boot_var".to_string(),
        "RELEASE_LIB".to_string(),
        release_lib.to_string_lossy().into_owned(),
        "-boot_var".to_string(),
        "RELEASE_ROOT".to_string(),
        release_dir.to_string_lossy().into_owned(),
        "-start_epmd".to_string(),
        "false".to_string(),
        "-noshell".to_string(),
    ];

    // Agregar argumentos del usuario
    for arg in env::args().skip(1) {
        args.push(arg);
    }

    // Spawn el proceso hijo
    let mut child: std::process::Child = if exec_mode == "daemon" {
        // Usar spawn_detached para crear una nueva sesión (portable: Linux y macOS)
        let erlexec_str = erlexec.to_string_lossy().into_owned();
        let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let rootdir_str = release_dir.to_string_lossy().into_owned();
        let bindir_str = bin_path.to_string_lossy().into_owned();
        let erl_libs_str = release_lib.to_string_lossy().into_owned();
        let sys_config_str = releases_version_dir
            .join("sys.config")
            .to_string_lossy()
            .into_owned();
        let vm_args_str = releases_version_dir
            .join("vm.args")
            .to_string_lossy()
            .into_owned();
        let env: Vec<(&str, &str)> = vec![
            ("ROOTDIR", &rootdir_str),
            ("BINDIR", &bindir_str),
            ("ERL_LIBS", &erl_libs_str),
            ("RELEASE_ROOT", &rootdir_str),
            ("RELEASE_PROG", app_name),
            ("RELEASE_SYS_CONFIG", &sys_config_str),
            ("RELEASE_VM_ARGS", &vm_args_str),
            ("EMU", "beam"),
            ("PROGNAME", "erl"),
        ];
        spawn_detached(&erlexec_str, &args_refs, &env)?;
        return Ok(0);
    } else {
        // Modo normal: ejecutar directamente
        let mut cmd = Command::new(&erlexec);
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
            // Desactivar EPMD para evitar cuelgues
            .arg("-start_epmd")
            .arg("false")
            .arg("-noshell")
            // Pasar argumentos a la aplicación
            .arg("-extra")
            .arg("--")
            .args(env::args().skip(1))
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());

        cmd.spawn().context("Failed to spawn Erlang VM process")?
    };

    // Esperar según el modo
    if exec_mode != "daemon" {
        let status = child.wait().context("Failed to wait for Erlang process")?;
        restore_terminal();
        Ok(status.code().unwrap_or(0) as u8)
    } else {
        Ok(0)
    }
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
    fn test_get_exec_mode_is_compiled() {
        // Just verify it doesn't crash
        let mode = get_exec_mode();
        assert!(!mode.is_empty());
    }

    #[test]
    fn test_get_app_name_is_compiled() {
        let app = get_app_name();
        assert!(!app.is_empty());
    }

    #[test]
    fn test_get_format_is_compiled() {
        let format = get_format();
        assert!(!format.is_empty());
    }

    #[test]
    fn test_get_release_version_reads_start_erl_data() {
        let temp_dir = tempfile::tempdir().unwrap();
        let releases_dir = temp_dir.path().join("releases");
        fs::create_dir(&releases_dir).unwrap();

        // Create start_erl.data with known version
        let start_erl = releases_dir.join("start_erl.data");
        fs::write(&start_erl, "16.0 2.5.1\n").unwrap();

        let version = get_release_version(temp_dir.path());
        assert_eq!(version, "2.5.1");
    }

    #[test]
    fn test_get_release_version_fallback_to_directory() {
        let temp_dir = tempfile::tempdir().unwrap();
        let releases_dir = temp_dir.path().join("releases");
        fs::create_dir(&releases_dir).unwrap();

        // Create version directory
        fs::create_dir(releases_dir.join("1.0.0")).unwrap();

        let version = get_release_version(temp_dir.path());
        assert_eq!(version, "1.0.0");
    }

    #[test]
    fn test_get_release_version_fallback_to_default() {
        let temp_dir = tempfile::tempdir().unwrap();
        // No releases directory at all

        let version = get_release_version(temp_dir.path());
        assert_eq!(version, "0.1.0");
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

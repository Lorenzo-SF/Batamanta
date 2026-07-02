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
    use std::ffi::{CStr, CString};
    use nix::unistd::{fork, setsid, execve, ForkResult};

    match unsafe { fork()? } {
        ForkResult::Parent { child: _ } => {
            std::thread::sleep(std::time::Duration::from_millis(500));
            Ok(())
        }
        ForkResult::Child => {
            setsid().context("setsid failed")?;

            // Build full environment: inherit parent env + merge additional vars
            let mut full_env: std::collections::HashMap<String, String> = std::env::vars().collect();
            for (k, v) in env {
                full_env.insert(k.to_string(), v.to_string());
            }

            let env_vec: Vec<CString> = full_env
                .iter()
                .map(|(k, v)| CString::new(format!("{}={}", k, v)).unwrap())
                .collect();
            let env_refs: Vec<&CStr> = env_vec.iter().map(CString::as_c_str).collect();

            let args_vec: Vec<CString> = std::iter::once(program)
                .chain(args.iter().copied())
                .map(|s| CString::new(s).unwrap())
                .collect();
            let args_refs: Vec<&CStr> = args_vec.iter().map(CString::as_c_str).collect();
    let app_bin_maybe = CString::new(program).context("Failed to convert program")?;
    let app_bin = app_bin_maybe.as_c_str();

    execve(&app_bin, &args_refs, &env_refs)?; Ok(())
        }
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

/// Deriva el nombre del módulo CLI a partir del nombre de la app.
///
/// Sigue la convención de Alaja: app `:delfos` → módulo `Delfos.CLI`,
/// app `:my_app` → módulo `MyApp.CLI`, etc.
/// Si el nombre está vacío, devuelve `None` (no hay módulo CLI derivable).
fn derive_cli_module(app_name: &str) -> Option<String> {
    if app_name.is_empty() {
        return None;
    }
    let pascal: String = app_name
        .split('_')
        .filter(|s| !s.is_empty())
        .map(|s| {
            let mut chars = s.chars();
            match chars.next() {
                None => String::new(),
                Some(c) => c.to_uppercase().to_string() + chars.as_str(),
            }
        })
        .collect();
    if pascal.is_empty() {
        None
    } else {
        Some(format!("{}.CLI", pascal))
    }
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
    // Include payload at compile time using OUT_DIR
    // build.rs will copy the payload to OUT_DIR during compilation
    let bytes = include_bytes!(concat!(env!("OUT_DIR"), "/payload.tar.zst"));

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

    // Daemon mode: NEVER cleanup temp dir because Erlang lives in background
    // The spawned Erlang process outlives the Rust dispenser
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
        // Release mode: use erlexec with boot scripts (full OTP release)
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
            let path_val = format!("{}:{}", bindir_str, env::var("PATH").unwrap_or_default());
            let erts_dir_str = erts_dir.to_string_lossy().into_owned();
            let env: Vec<(&str, &str)> = vec![
                ("BINDIR", &bindir_str),
                ("ERL_LIBS", &erl_libs_str),
                ("ERL_ROOTDIR", &erts_dir_str),
                ("ROOTDIR", &rootdir_str),
                ("EMULATOR", "beam"),
                // FIX: bundled ERTS bin first in PATH; neutralize any Erlang env vars
                // from the shell (asdf/mise/kerl/manual install) that could cause
                // BEAM startup to locate the wrong ERTS libraries.
                ("PATH", &path_val),
                ("ERL_FLAGS", ""),
                ("ERL_AFLAGS", ""),
                ("ERL_ZFLAGS", ""),
                // ESCRIPT_EMULATOR avoids escript calling the erl shell script
                // which has a hard-coded erts-X.Y/ BINDIR path baked in.
                ("ESCRIPT_EMULATOR", "erlexec"),
            ];
            spawn_detached(&wrapper_script_str, &args, &env)?;
            return Ok(0);
        } else {
            let mut c = Command::new(&wrapper_script_str);
            // FIX: set env on the wrapper subprocess explicitly.
            // System.cmd(env:) in Elixir replaces the env entirely (Port behaviour),
            // but here in Rust, Command::new inherits the parent env unless we
            // override. We prepend the bundled ERTS bin to PATH and neutralize
            // any Erlang env vars from the shell so the wrapper's `exec escript`
            // uses only the bundled ERTS, ignoring asdf/mise/kerl/manual installs.
            let bindir_str = erts_bin_dir.to_string_lossy().into_owned();
            let erl_libs_str = erts_dir.join("lib").to_string_lossy().into_owned();
            let rootdir_str = escript_path
                .parent()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            c.env(
                "PATH",
                format!("{}:{}", bindir_str, env::var("PATH").unwrap_or_default()),
            )
            .env("BINDIR", &bindir_str)
            .env("ERL_LIBS", &erl_libs_str)
            .env("ERL_ROOTDIR", erts_dir.to_string_lossy().as_ref())
            .env("ROOTDIR", &rootdir_str)
            .env("EMULATOR", "beam")
            .env("ERL_FLAGS", "")
            .env("ERL_AFLAGS", "")
            .env("ERL_ZFLAGS", "")
            // ESCRIPT_EMULATOR avoids escript calling the erl shell script
            // which has a hard-coded erts-X.Y/ BINDIR path baked in.
            .env("ESCRIPT_EMULATOR", "erlexec")
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
            c
        };

        // Configurar raw mode ANTES de iniciar el escript si es modo TUI
        if exec_mode == "tui" {
            Command::new("stty")
                .args(["-icanon", "-echo"])
                .stdin(Stdio::inherit())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .ok();
        }

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
            .env("ERL_ROOTDIR", erts_dir.to_string_lossy().as_ref())
            .env("EMULATOR", "beam")
            // FIX: neutralize Erlang env vars from the shell on Windows too.
            .env("ERL_FLAGS", "")
            .env("ERL_AFLAGS", "")
            .env("ERL_ZFLAGS", "");

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
    use std::io::Write; use uuid::Uuid;

    let wrapper_path =
        env::temp_dir().join(format!("batamanta_escript_wrapper_{}", Uuid::new_v4()));

    // El escript ya tiene el shebang, solo necesitamos configurar el PATH y vars
    let erts_lib_dir = erts_dir.join("lib");

    // Determinar si es modo daemon basado en si setsid nos pasó el flag
    let daemon_flag = if exec_mode == "daemon" { "-daemon" } else { "" };

    let wrapper_content = format!(
        r#"#!/bin/sh
# Batamanta escript wrapper — generated automatically.
#
# We invoke the bundled OTP escript(1) tool DIRECTLY with the escript file
# as its argument instead of exec-ing the escript file by path.  Exec-by-path
# would trigger shebang (#!/usr/bin/env escript) resolution, which resolves
# "escript" from the *inherited* PATH — possibly landing on the system OTP
# and not the bundled one.  Direct invocation bypasses that entirely.

BINDIR="{bindir}"
ERL_ROOTDIR="{erts_dir}"
ERL_LIBS="{erts_lib_dir}"
ESCRIPT_FILE="{escript}"
PROGNAME="{app_name}"

# Bundled ERTS bin must come first so every OTP tool (erl, escript, erlexec,
# beam.smp) resolves to the bundled version, never to a system/asdf/mise shim.
export PATH="$BINDIR:$PATH"

export ROOTDIR="$ERL_ROOTDIR"
export BINDIR="$BINDIR"
export ERL_LIBS="$ERL_LIBS"
export EMU="beam"
export EMULATOR="beam"
export PROGNAME="$PROGNAME"
export RELEASE_ROOT="$ERL_ROOTDIR"
# ERL_ROOTDIR must be exported too — the bundled `erl` script checks this
# variable first.  Without it, `erl` falls back to the hard-coded path that
# was baked in when the OTP tarball was built (typically something like
# /opt/erlang/lib/erlang), which does not exist on the target machine.
export ERL_ROOTDIR="$ERL_ROOTDIR"

# ESCRIPT_EMULATOR tells escript(1) which binary to use as the Erlang
# emulator.  The default is "erl" (a shell script that hardcodes the
# ERTS version into BINDIR and calls erlexec).  Because batamanta
# flattens the ERTS directory structure — there is no erts-X.Y/
# subdirectory — the erl script's hard-coded path points at nothing.
# Using "erlexec" directly avoids that: erlexec uses environment
# variables (BINDIR, ROOTDIR, EMU, PROGNAME) dynamically and has no
# baked-in version directory.
export ESCRIPT_EMULATOR="erlexec"

# Neutralize any Erlang env vars inherited from the shell.  These can alter
# BEAM startup flags or point to the wrong OTP installation.
export ERL_FLAGS=""
export ERL_AFLAGS=""
export ERL_ZFLAGS=""
# Clear version-manager pins so their shims (if still in PATH for elixir/mix)
# forward erl lookups to whichever erl is first — ours.
unset ASDF_ERLANG_VERSION
unset MISE_ERLANG_VERSION

# Strip the internal -daemon sentinel from user-visible arguments,
# preserving each argument as a separate word (no quoting artifacts).
for arg in "$@"; do
    shift
    [ "$arg" = "-daemon" ] && continue
    set -- "$@" "$arg"
done

# Invoke the bundled escript tool directly, passing the escript file as the
# first argument.  This avoids any shebang/PATH ambiguity.
ESCRIPT_BIN="$BINDIR/escript"
if [ ! -x "$ESCRIPT_BIN" ]; then
    # Fallback: some minimal ERTS builds only ship erlexec; use erl -run escript.
    ESCRIPT_BIN="$BINDIR/erl"
    exec "$ESCRIPT_BIN" -noshell -run escript start "$ESCRIPT_FILE" "$@"
fi

if [ -n "{daemon_flag}" ]; then
    exec "$ESCRIPT_BIN" "$ESCRIPT_FILE" -noshell "$@"
else
    exec "$ESCRIPT_BIN" "$ESCRIPT_FILE" "$@"
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
    _exec_mode: &str,
) -> Result<u8> {
    // Locate erlexec and the ERTS root.
    //
    // The Mix release layout is `<release>/erts-X.Y/bin/erlexec` and
    // `ROOTDIR=<release>` (the parent of `erts-X.Y/`). The `bin/erl`
    // shell script in that layout computes `ROOTDIR` the same way
    // and we mirror it here so we can call `erlexec` directly without
    // the shell wrapper.
    //
    // We accept three layouts to stay robust across history:
    //   1) <release>/erts-X.Y/bin/erlexec      — standard Mix release
    //   2) <release>/erts/bin/erlexec          — old batamanta flat
    //   3) <release>/bin/erlexec                — include_erts: true,
    //                                             ERTS fused into bin/
    let erts_subdir_bin = release_dir.join("erts").join("bin");
    let erlexec = find_file(bin_dir, "erlexec")
        .or_else(|| find_file_with_prefix(release_dir, "erts-", "erlexec"))
        .or_else(|| find_file(&erts_subdir_bin, "erlexec"))
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

    // ROOTDIR must point to where the boot script's `$ROOT/lib/kernel-*`
    // can find kernel, stdlib, etc.
    //
    // In a standard Mix release (`include_erts: true`), kernel lives at
    // `<release>/lib/kernel-*` and ROOTDIR = `<release>`. When
    // `include_erts: false`, the release has no kernel in lib/ — it's
    // bundled inside the ERTS at `<release>/erts-X.Y/lib/` — so ROOTDIR
    // must point to the ERTS directory.
    //
    // Heuristic: check if `<release>/lib/kernel-*` exists.
    let has_kernel_in_release_lib = std::fs::read_dir(release_dir.join("lib"))
        .ok()
        .map(|mut entries| {
            entries.any(|e| {
                e.ok()
                    .and_then(|e| e.file_name().to_str().map(|s| s.to_string()))
                    .map_or(false, |name| name.starts_with("kernel-"))
            })
        })
        .unwrap_or(false);

    let rootdir = if has_kernel_in_release_lib {
        // Standard release or fused ERTS: kernel at <release>/lib/kernel-*
        release_dir.to_path_buf()
    } else {
        // include_erts: false or old flat layout: kernel inside the bundled
        // ERTS directory. The ERTS dir is the parent of bin_path.
        bin_path
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| release_dir.to_path_buf())
    };

    // Detectar dinámicamente la versión del release
    let release_version = get_release_version(release_dir);
    let releases_version_dir = release_dir.join("releases").join(&release_version);

    // La estrategia de boot se decide por `exec_mode` configurado en mix.exs:
    //
    //   :cli     → SIEMPRE start.boot + -eval <Module>.main([args]) + -s init stop.
    //              El módulo CLI deriva del app_name ("Delfos.CLI" para :delfos).
    //              Haya o no argumentos: el CLI muestra help/usage si está vacío.
    //              Esto arregla el bug de delfos que se colgaba al lanzarse sin args.
    //
    //   :daemon  → start.boot + -extra --. La app lee args de
    //              `:init.get_plain_arguments()` en su Application.start/2.
    //              Ella misma gestiona su ciclo de vida (System.halt/1, etc.).
    //
    //   :tui     → Igual que daemon pero el wrapper Rust pone la terminal en raw
    //              mode (stty -icanon -echo) antes de spawnear el VM.
    //
    // Si no se puede derivar el módulo CLI del app_name, se cae a daemon mode.
    let user_args: Vec<String> = env::args().skip(1).collect();
    let exec_mode = get_exec_mode();
    let cli_module = if exec_mode == "cli" {
        derive_cli_module(&get_app_name())
    } else {
        None
    };

    // Seleccionar el archivo .boot según el modo:
    //
    //   :cli  → start_clean.boot (inicia solo kernel/stdlib/Elixir).
    //           El módulo CLI via `-eval Delfos.CLI.main([args])` arranca
    //           la app completa vía `Application.ensure_all_started/1` y
    //           `-s init stop` apaga la VM al terminar.
    //
    //   :daemon / :tui  → start.boot (supervision tree completo).
    //           La app lee args de `:init.get_plain_arguments()` y gestiona
    //           su propio ciclo de vida.
    let boot_path = if exec_mode == "cli" {
        let clean = releases_version_dir.join("start_clean.boot");
        if clean.exists() {
            clean
        } else {
            find_file_by_ext(&release_dir.join("releases"), "boot")
                .filter(|p| {
                    p.file_name()
                        .and_then(|s| s.to_str())
                        .map(|n| n == "start_clean.boot")
                        .unwrap_or(false)
                })
                .or_else(|| find_file_by_ext(bin_dir, "boot"))
                .context("No start_clean.boot found for CLI mode")?
        }
    } else {
        let full = releases_version_dir.join("start.boot");
        if full.exists() {
            full
        } else {
            find_file_by_ext(&release_dir.join("releases"), "boot")
                .filter(|p| {
                    let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                    name == "start.boot" || !name.contains("start_clean")
                })
                .or_else(|| find_file_by_ext(bin_dir, "boot"))
                .context("No .boot file found")?
        }
    };

    let boot_arg = boot_path.with_extension("").to_string_lossy().into_owned();

    // Construir argumentos base del VM
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

    // En CLI mode: despachar vía -eval <Module>.main([args]) + -s init stop.
    // En daemon mode: pasar args via -extra -- para :init.get_plain_arguments().
    if let Some(module) = cli_module {
        // Escapar cada arg como binario Erlang (<<"text">>) para que
        // Elixir lo reciba como string (binario), no como charlist.
        let quoted: Vec<String> = user_args
            .iter()
            .map(|a| {
                // Escapar backslash y comillas para Erlang binary syntax
                let escaped = a.replace('\\', "\\\\").replace("\"", "\\\"");
                format!("<<\"{}\">>", escaped)
            })
            .collect();
        let elixir_list = quoted.join(", ");

        // -eval usa sintaxis Erlang. Llamamos la función Elixir desde
        // Erlang usando el átomo 'Elixir.Modulo' y pasamos los args
        // como binarios (<<>>) que Elixir ve como strings.
        // Ejemplo: 'Elixir.Delfos.CLI':main([<<"version">>])
        args.push("-eval".to_string());
        args.push(format!("'Elixir.{}':main([{}])", module, elixir_list));
        args.push("-s".to_string());
        args.push("init".to_string());
        args.push("stop".to_string());
    } else {
        // Daemon mode: pasar args para :init.get_plain_arguments()
        args.push("-extra".to_string());
        args.push("--".to_string());
        for arg in &user_args {
            args.push(arg.clone());
        }
    }

    // ERL_LIBS for runtime code path resolution. With the standard
    // Mix release layout (erts-X.Y/lib/*, lib/*) the boot script
    // already populates the code path, so we only need release_lib
    // here. Kept as a single entry to avoid masking bad layouts.
    let erl_libs_str = release_lib.to_string_lossy().into_owned();

    let mut child: std::process::Child = if exec_mode == "daemon" {
        // Usar spawn_detached para crear una nueva sesión (portable: Linux y macOS)
        let erlexec_str = erlexec.to_string_lossy().into_owned();
        let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let rootdir_str = rootdir.to_string_lossy().into_owned();
        let release_root_str = release_dir.to_string_lossy().into_owned();
        let bindir_str = bin_path.to_string_lossy().into_owned();
        let sys_config_str = releases_version_dir
            .join("sys.config")
            .to_string_lossy()
            .into_owned();
        let vm_args_str = releases_version_dir
            .join("vm.args")
            .to_string_lossy()
            .into_owned();
        let mut env = vec![
            ("ROOTDIR", rootdir_str.as_str()),
            ("BINDIR", bindir_str.as_str()),
            ("ERL_LIBS", erl_libs_str.as_str()),
            ("ERL_ROOTDIR", rootdir_str.as_str()),
            ("RELEASE_ROOT", release_root_str.as_str()),
            ("RELEASE_PROG", app_name),
            ("RELEASE_SYS_CONFIG", sys_config_str.as_str()),
            ("RELEASE_VM_ARGS", vm_args_str.as_str()),
            ("EMU", "beam"),
            ("PROGNAME", "erl"),
            // FIX: neutralize Erlang env vars from the shell so the daemon BEAM
            // uses only the bundled ERTS, ignoring asdf/mise/kerl/manual installs.
            ("ERL_FLAGS", ""),
            ("ERL_AFLAGS", ""),
            ("ERL_ZFLAGS", ""),
        ];
        let path_val = format!("{}:{}", bindir_str, env::var("PATH").unwrap_or_default());
        env.push(("PATH", path_val.as_str()));
        spawn_detached(&erlexec_str, &args_refs, &env)?;
        return Ok(0);
    } else {
        // Modo normal: ejecutar directamente

        // Configurar raw mode ANTES de iniciar el VM si es modo TUI
        // El wrapper Rust tiene acceso al terminal real, a diferencia
        // de los procesos spawnheados por el VM de Erlang.
        if exec_mode == "tui" {
            Command::new("stty")
                .args(["-icanon", "-echo"])
                .stdin(Stdio::inherit())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .ok();
        }

        let sys_config_path = releases_version_dir.join("sys.config");
        let vm_args_path = releases_version_dir.join("vm.args");

        // Construir el comando usando el vector `args` que ya contiene
        // todos los argumentos base (-boot, -boot_var, -noshell) MÁS
        // los argumentos específicos del modo:
        //   - CLI:  -eval <Mod>.main([...]) + -s init stop
        //   - TUI:  (sin -eval, sin -extra, mismo que daemon)
        //   - Daemon: -extra --
        //
        // Luego se añaden los argumentos extra que erlexec/beam necesitan
        // y que NO están en el vector `args`: --erl-config, -args_file.
        let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

        let mut cmd = Command::new(&erlexec);
        cmd.env("ROOTDIR", &rootdir)
            .env("BINDIR", bin_path)
            .env("ERL_LIBS", &erl_libs_str)
            .env("ERL_ROOTDIR", &rootdir)
            .env("RELEASE_ROOT", release_dir)
            .env("RELEASE_PROG", app_name)
            .env("RELEASE_SYS_CONFIG", &sys_config_path)
            .env("RELEASE_VM_ARGS", &vm_args_path)
            .env("EMU", "beam")
            .env("PROGNAME", "erl")
            // Neutralize Erlang env vars from the shell so the BEAM uses
            // only the bundled ERTS, ignoring asdf/mise/kerl/manual installs.
            .env("ERL_FLAGS", "")
            .env("ERL_AFLAGS", "")
            .env("ERL_ZFLAGS", "")
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    bin_path.display(),
                    env::var("PATH").unwrap_or_default()
                ),
            )
            // Todos los argumentos del vector (boot, boot_var, -eval, -s, etc.)
            .args(&args_refs)
            // FIX: pass sys.config so application env is loaded correctly.
            // erlexec takes --erl-config <path> (WITHOUT .config extension)
            .arg("--erl-config")
            .arg(sys_config_path.with_extension(""))
            // FIX: pass vm.args so VM flags (node name, cookie, etc.) are applied.
            .args(if vm_args_path.exists() {
                vec![
                    "-args_file".to_string(),
                    vm_args_path.to_string_lossy().into_owned(),
                ]
            } else {
                vec![]
            })
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

/// Find `name` inside any `prefix*` sibling of `parent` whose name
/// starts with `prefix`.
///
/// Used to locate `<release>/erts-X.Y/bin/erlexec` without knowing
/// the exact `X.Y` at compile time. Returns the first match.
fn find_file_with_prefix(parent: &Path, prefix: &str, name: &str) -> Option<PathBuf> {
    let entries = fs::read_dir(parent).ok()?;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir()
            && p.file_name()
                .and_then(|s| s.to_str())
                .map(|s| s.starts_with(prefix))
                .unwrap_or(false)
        {
            if let Some(found) = find_file(&p, name) {
                return Some(found);
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

    /// `find_file_with_prefix` locates a file inside a sibling
    /// directory whose name starts with the given prefix — used to
    /// find `erts-X.Y/bin/erlexec` without hardcoding the version.
    #[test]
    fn test_find_file_with_prefix_locates_versioned_erts() {
        let temp_dir = tempfile::tempdir().unwrap();
        let nested = temp_dir.path().join("erts-16.3");
        let nested_bin = nested.join("bin");
        fs::create_dir_all(&nested_bin).unwrap();
        let erlexec = nested_bin.join("erlexec");
        File::create(&erlexec).unwrap();

        let result = find_file_with_prefix(temp_dir.path(), "erts-", "erlexec");
        assert!(result.is_some());
        assert_eq!(result.unwrap(), erlexec);
    }

    #[test]
    fn test_find_file_with_prefix_returns_none_when_no_match() {
        let temp_dir = tempfile::tempdir().unwrap();
        let result = find_file_with_prefix(temp_dir.path(), "erts-", "erlexec");
        assert!(result.is_none());
    }

    #[test]
    fn test_find_file_with_prefix_skips_unrelated_dirs() {
        let temp_dir = tempfile::tempdir().unwrap();
        // lib/ is a sibling but does not start with "erts-".
        let lib = temp_dir.path().join("lib");
        fs::create_dir_all(&lib).unwrap();
        File::create(lib.join("erlexec")).unwrap();

        let result = find_file_with_prefix(temp_dir.path(), "erts-", "erlexec");
        assert!(result.is_none());
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
        let result = find_file_by_ext(temp_dir.path(), "nonexistent");
        assert!(result.is_none());
    }

    /// Verifica la búsqueda de `erlexec` con el orden de preferencia del fix:
    ///   1) <release>/bin/erlexec
    ///   2) <release>/erts/bin/erlexec
    ///   3) búsqueda genérica en <release>
    /// Esto cubre el caso `include_erts: false` (release con ERTS
    /// flattenizado en `release/erts/bin/erlexec`) que era el origen
    /// del `load_failed` en kernel/stdlib.
    #[test]
    fn test_find_erlexec_prefers_flattened_erts_bin() {
        let temp_dir = tempfile::tempdir().unwrap();
        let release_dir = temp_dir.path();
        let bin_dir = release_dir.join("bin");
        let erts_subdir_bin = release_dir.join("erts").join("bin");

        // Caso típico de batamanta con `include_erts: false`:
        // erlexec en release/erts/bin/ (flattenizado), nada en release/bin/.
        fs::create_dir_all(&erts_subdir_bin).unwrap();
        let erlexec_in_erts = erts_subdir_bin.join("erlexec");
        File::create(&erlexec_in_erts).unwrap();

        let result = find_file(&bin_dir, "erlexec")
            .or_else(|| find_file(&erts_subdir_bin, "erlexec"))
            .or_else(|| find_file(release_dir, "erlexec"));

        assert!(result.is_some(), "erlexec should be found in erts/bin/");
        assert_eq!(result.unwrap(), erlexec_in_erts);
    }

    #[test]
    fn test_find_erlexec_prefers_release_bin_when_both_exist() {
        let temp_dir = tempfile::tempdir().unwrap();
        let release_dir = temp_dir.path();
        let bin_dir = release_dir.join("bin");
        let erts_subdir_bin = release_dir.join("erts").join("bin");

        fs::create_dir_all(&bin_dir).unwrap();
        fs::create_dir_all(&erts_subdir_bin).unwrap();
        let erlexec_in_bin = bin_dir.join("erlexec");
        File::create(&erlexec_in_bin).unwrap();
        File::create(erts_subdir_bin.join("erlexec")).unwrap();

        let result = find_file(&bin_dir, "erlexec")
            .or_else(|| find_file(&erts_subdir_bin, "erlexec"))
            .or_else(|| find_file(release_dir, "erlexec"));

        assert!(result.is_some());
        // Cuando el ERTS está fusionado en bin/ (include_erts: true),
        // esa ubicación debe ganar para preservar la lógica legacy.
        assert_eq!(result.unwrap(), erlexec_in_bin);
    }
}

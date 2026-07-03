# Batamanta — Agent Summary

## Goal
Re-arquitecturar batamanta: wrapper Rust minimalista (~100 líneas, solo extraer + exec) + script `.run` generado por Elixir en build time con todo el entorno (PATH, BINDIR, neutralización), eliminando flattening del ERTS y los parches asociados.

## Constraints & Preferences
- batamanta debe soportar TODAS las combinaciones: OS (linux glibc, linux musl, macos) × arch (amd64, arm) × exec mode (cli, tui, daemon) × format (escript, release) × proyecto (standalone, umbrella) × NIFs × argv × OTP 25.0–28.x.
- El wrapper NO debe reimplementar lógica de boot — solo extraer payload y exec el script `.run`.
- El script `.run` se genera en BUILD TIME (Elixir) con toda la configuración de entorno — cambiar env vars NO requiere recompilar Rust.
- delfos es el consumidor principal y debe seguir funcionando como CLI (`delfos doctor`).
- Sin flattening del ERTS: se mantiene la estructura original `erts-X.Y/` que es autoconsistente.
- `ESCRIPT_EMULATOR=erlexec` NO funciona en OTP ≤ 26; `escript` usará `erl` (vía PATH) que encuentra `erlexec` correctamente sin necesidad de la variable.
- No tocar smoke tests hasta que todo el refactor esté completo.
- Sin Windows.

## Progress
### Done
- T-001 (Spike): Identificadas las únicas env vars críticas: `PATH` (apuntando a `erts-X.Y/bin`) + `BINDIR` (misma ruta). `ESCRIPT_EMULATOR` no sirve en OTP ≤26. Sin flattening, el ERTS bundled es autoconsistente — `erl`, `escript`, `erlexec`, `dyn_erl` funcionan sin parches extra.
- T-002: Creado `Batamanta.RunScript` que genera el script `.run` con PATH, BINDIR, neutralización asdf/mise, y soporta las 6 combinaciones (escript/release × cli/daemon/tui).
- T-003: Integrado RunScript en `Packager.package/4` (release) y `EscriptPackager.package/4` (escript). Añadida función `get_erts_version/1` a ambos packagers. Mix task pasa `execution_mode` a ambos packagers. Compila limpio.
- Fix commit `83c4580`: `--erl-config` → `-config` + extensión `.config`.
- Fix commit `bf77112`: `RELEASE_SYS_CONFIG` sin `.config` doble.
- T-004: Eliminado flattening del ERTS + parches asociados en `packager.ex`:
  - Eliminadas: `flatten_nested_erts`, `patch_erl_script_for_bundled_erlexec`, `patch_erl_script_content`, `patch_string`, `fix_broken_symlinks`, `patch_add_rootdir_boot_var`
  - `collect_files` prefix cambiado de `"release/erts"` a `"release"` para ambos (release + ERTS)
  - `patch_bin_app_for_bundled_erlexec` simplificado: solo parchea `--erl-config`, eliminado `--boot-var ROOTDIR`
  - `ensure_executable_permissions` corregido: patrón `erts/*/bin` → `erts-*/bin`
  - `cleanup_erts` extendido: elimina `releases/` del ERTS (evita conflicto con releases del release)
- T-005: Fix escript format:
  - **Problema**: sin flattening, erl script (`erts-X.Y/bin/erl`) tiene `BINDIR="$ROOTDIR/erts-X.Y/bin"`. escript invoca `erl` vía PATH, dyn_erl computa ROOTDIR como el release root.
  - **Solución escript**: `ERL_ROOTDIR="$ERTS_DIR"` en el `.run` script (escript case only) + `patch_erl_script` que cambia BINDIR a `"$ROOTDIR/bin"` → BINDIR = `erts-X.Y/bin/` (correcto). + `copy_boot_files_to_release_bin` copia `no_dot_erlang.boot` etc a `release/bin/` para que erlexec los encuentre vía `$ROOTDIR/bin/`.
  - **Release format**: no necesita cambios — dyn_erl resuelve ROOTDIR correctamente, erl script no se invoca en el path release.
  - Limpiadas dependencias Rust muertas: `sha2`, `uuid`, `ctrlc`, `md5`, `libc`. md5 reemplazado por hash inline del prefijo del payload.

### Blocked
- (ninguno)

## Key Decisions
- **Wrapper minimalista** (~100 líneas): extraer payload + exec `release/bin/<app>.run`. Toda la lógica de entorno vive en el script `.run` generado por Elixir.
- **Sin flattening**: ERTS mantiene `erts-X.Y/`. Esto elimina `patch_erl_script_for_bundled_erlexec`, `fix_broken_symlinks`, y el parche `--boot-var ROOTDIR` en `bin/<app>`. Solo se conserva `--erl-config → -config`.
- **Sin ESCRIPT_EMULATOR**: En OTP ≤26, `escript` invoca `erl` vía PATH, y `erl` script encuentra `erlexec` correctamente con la estructura no aplanada.
- **Solo se necesita `PATH` + `BINDIR`** para que todo el chain funcione: `escript` → `erl` → `erlexec` → `beam.smp`.
- **`collect_files` usa prefix `"release"` para ambos**: el ERTS y el release se colocan al mismo nivel en el payload. El ERTS provee `erts-X.Y/bin/erlexec`, `lib/kernel-*`, `lib/stdlib-*`, etc. El release provee `bin/<app>`, `lib/<app>-<vsn>/`, `releases/<vsn>/`.
- **`--boot-var ROOTDIR` eliminado**: erlexec computa ROOTDIR correctamente desde su path (`release/erts-14.2/bin/erlexec` → ROOTDIR = `release/erts-14.2/`).
- **ERTS `releases/` eliminado** del working copy: el release tiene su propio `releases/` con boot scripts y config; el ERTS solo aporta `start_erl.data` que ya es sobrescrito por `update_start_erl_data`.
- **No aumentar carga cognitiva**: si no es necesario para el core, no se toca (banner.ex, env_cleaner.ex, target.ex, erts/fetcher.ex se quedan como están).

## Next Steps
1. T-005: limpiar DEBUG prints en packager.ex.
2. T-006: revisar build.rs — si el .run script lleva toda la configuración inline, `GENERATED_EXEC_MODE` y `GENERATED_FORMAT` pueden eliminarse.
3. T-007: refactorizar `main.rs` a ~100 líneas — eliminar `build_isolated_env`, `find_file`, `get_release_version`, `derive_cli_module`. Solo `extract_payload` + `exec(".run")`.
4. Revisión final: reanalizar el proyecto entero para detectar faltantes.

## Critical Context
- **Bug confirmado**: `patch_erl_script_content` buscaba `erts-16.3` (hardcoded) → no parcheaba nada con ERTS 14.2. Código eliminado en T-004.
- **Bug confirmado**: `build_isolated_env` no setea `BINDIR` → `erlexec` invocado por nombre falla con "The emulator 'smp' does not exist". Se arreglará en T-007 cuando se elimine main.rs.
- **Bug confirmado**: `ESCRIPT_EMULATOR=erlexec` en OTP 26 genera `{'cannot get bootfile','no_dot_erlang.boot'}` — no soportado.
- **Hallazgo clave**: Sin flattening, el ERTS bundled funciona por sí solo con solo `PATH` + `BINDIR`. No necesita `ERL_ROOTDIR`, `EMU`, `ESCRIPT_EMULATOR`, ni parches de scripts.
- **Estructura final del payload** (sin flattening):
  ```
  release/
  ├── bin/<app>              ← release script
  ├── bin/<app>.run          ← entry point (generado)
  ├── bin/erl                ← del ERTS (top-level)
  ├── bin/escript            ← del ERTS (top-level)
  ├── bin/start.boot         ← del release (copiado por prepare_start_boot)
  ├── bin/no_dot_erlang.boot ← del ERTS (necesario para escript)
  ├── lib/kernel-9.2/        ← del ERTS
  ├── lib/stdlib-5.2/        ← del ERTS
  ├── lib/<app>/             ← app code
  ├── erts-14.2/bin/erlexec  ← VM (desde erts-14.2/)
  ├── erts-14.2/bin/beam.smp ← emulador
  └── releases/<versión>/    ← boot scripts
  ```
- **Errores comunes que desaparecen sin flattening**: "The emulator 'smp' does not exist", "cannot get bootfile", "erl: line 57: erlexec: No existe".
- `MANIFEST.json` sigue desviado del README (no hay tarballs darwin-x86_64 ni windows_x86_64 a pesar de estar anunciados) — sin tocar.
- `banner.ex` (441 líneas) es cosmético — sin tocar.

## Relevant Files
- `lib/batamanta/run_script.ex` (NUEVO): genera script `.run` con PATH, BINDIR, neutralización, soporte escript/release × cli/daemon/tui.
- `lib/batamanta/packager.ex`: contiene `get_erts_version/1` (NUEVO), `prepare_erts/1` (simplificado — sin flatten+patches), `patch_bin_app_for_bundled_erlexec` (solo parchea `--erl-config`).
- `lib/batamanta/escript_packager.ex`: contiene `get_erts_version/1` (NUEVO), `package/4` modificado para aceptar opts y generar `.run`.
- `lib/mix/tasks/batamanta.ex`: pasa `execution_mode` a `EscriptPackager.package/4`.
- `priv/rust_template/src/main.rs` (435 líneas): será reducido a ~100 líneas — solo extract + exec.
- `priv/rust_template/build.rs`: genera `GENERATED_EXEC_MODE`/`GENERATED_APP_NAME`/`GENERATED_FORMAT` — posiblemente eliminable tras T-006.
- `lib/batamanta/env_cleaner.ex` (349 líneas): neutraliza asdf/mise — no se toca.
- `lib/batamanta/erts/fetcher.ex` (767 líneas): download+retry+lock — no se toca.
- `lib/batamanta/target.ex` (426 líneas): matriz de targets — no se toca.
- `lib/batamanta/banner.ex` (441 líneas): detección de protocolo de terminal — no se toca (cosmético).

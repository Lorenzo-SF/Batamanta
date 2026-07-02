# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.1] - 2026-07-02

### Fixed

- Release-mode binaries now correctly load `sys.config` at boot. The
  Rust wrapper was passing `--erl-config <path>` (without the
  `.config` extension), a flag the bundled `erlexec` (OTP 28.4 /
  Erlang 16.3) does not recognise. Switched to the classic
  `-config <path-to-.config>` form, which works on every erlexec
  since OTP 17. Consumer apps were silently booting with no
  application env and crashing on first Postgres/Redis/etc. access
  with errors like `missing the :database key`.
- CLI release binaries: `RELEASE_SYS_CONFIG` env var was being set
  with the `.config` extension included. The Erlang `Config.Provider`
  machinery appends `.config` automatically, so the provider tried
  to read `sys.config.config` (double extension) and aborted boot.
  Fix: pass the path without `.config` in `RELEASE_SYS_CONFIG`,
  matching the convention of the standard Mix release `bin/app`
  script. Affects every consumer app that has a `config_provider_init`
  in its `sys.config` (i.e. uses `config/runtime.exs`).

## [1.6.0] - 2026-07-02

### Added
- **CLI dispatch via `-eval` + `start_clean.boot`**: CLI mode (`execution_mode: :cli`) now boots the VM with `start_clean.boot` (minimal boot — no application supervision tree) instead of `start.boot` (full release boot). CLI args are dispatched via `-eval 'Elixir.Module.CLI':main([<<"...">>])` followed by `-s init stop`, so the binary runs the CLI command and exits cleanly without ever starting OTP applications. Daemon and TUI modes continue using `start.boot` (full supervision tree).
- **`smoke_tests/test_escript_otp26`**: regression guard for escript builds targeting OTP 26 (OTP compatibility).
- **`smoke_tests/test_release_nif`**: regression guard that exercises `include_erts: false` with explicit `:erlang.system_info/1` + `Supervisor.start_link/2` calls that fail if `kernel`/`supervisor` did not load. Wired into `smoke_tests.sh`.
- **`derive_cli_module/1`**: derives the CLI module name from the app name at runtime (`:delfos` → `"Delfos.CLI"`, `:test_cli` → `"TestCli.CLI"`), following Alaja convention.
- **ROOTDIR heuristic**: new logic checks if `<release>/lib/kernel-*` exists to determine whether ROOTDIR should point to the release root (standard layout) or the bundled ERTS directory (`include_erts: false` layout).

### Fixed
- **CLI args silently dropped (critical)**: the `args` vector (containing `-eval`, `-s init stop`, and user arguments) was built but **never passed to the `Command`** in CLI mode. The `Command` was constructed from scratch with individual `.arg()` calls, duplicating only the base erlexec args. Now uses `.args(&args)` — the complete vector is passed to the spawned process.
- **CLI args as charlists instead of binaries**: `"version"` in Erlang syntax produces a charlist (`[118,101,114,...]`), which Elixir receives as `'version'` (charlist) instead of `"version"` (string). All CLI arg comparisons using `== "version"` evaluated to `false`, causing `'unknown command'` errors. Fixed by formatting args as Erlang binary syntax: `<<"version">>`.
- **CLI mode used `start.boot` (full supervision tree)**: before this release, `exec_mode == :cli` still started the full OTP release (`start.boot`), starting the application supervisor tree, Ecto repos, and all children. The CLI command ran as a side effect after the full tree started, and `-s init stop` was ineffective because the supervision tree kept the VM alive. Daemon/TUI remain unaffected.
- **`exec_mode` overridden by args presence**: `cli_mode = !user_args.is_empty()` in `run_with_erlexec` meant any binary launched without arguments entered daemon mode even when `execution_mode: :cli` was configured. An empty-args CLI binary (e.g. `delfos` with no subcommand) would boot the full supervision tree and hang forever. Now `exec_mode` is the sole determinant of boot strategy.
- **`--erl-config` vs `-config` flag**: previous releases used the `-config` flag for erlexec, which is unsupported in newer OTP versions. Changed to `--erl-config` for compatibility.
- **Release mode boot crash (`load_failed` on kernel/stdlib)**: when a release is built with `include_erts: false` (or when batamanta flattens the ERTS into `release/erts/`), the wrapper's `ROOTDIR` was set to the release root, but the boot script references `$ROOT/lib/kernel-*`, `$ROOT/lib/stdlib-*`, etc. Those modules live in the bundled ERTS, not in `release/lib/`. The VM crashed on boot with `{load_failed,[supervisor,kernel,...]}`. The wrapper now detects where `erlexec` actually lives and points `ROOTDIR` to the bundled ERTS directory when it is flattened. Two new Rust unit tests cover the `include_erts: true` and `include_erts: false` layouts.
- **Umbrella release builds were silently broken**: `run_umbrella_release/7` ran `mix release` from the umbrella root (no `cd:`), so only the root's release (typically a no-op) was ever built. The sub-app releases were never assembled. The loop now iterates sub-apps and runs `mix release` with `cd: app_path` so each sub-app produces its own release.
- **Umbrella `get_release_path/1` pointed at the wrong directory**: the function computed `<root>/_build/prod/rel/<app>` for every app, but in a sub-app the release lives in `<sub_app>/_build/prod/rel/<app>`. Now accepts an optional `app_path` argument; the umbrella caller passes the sub-app path while the standalone path is unchanged. Four new unit tests cover standalone, single-level umbrella, nested umbrella, and `app_path` precedence.
- **`flatten_nested_erts` removed from `Packager.prepare_erts/1`**: the flattening step was accidentally removed in a previous refactor, causing `include_erts: false` releases to have a malformed ERTS layout (erlexec two levels deep). Restored the call to ensure erlexec and kernel are at the same level under ROOTDIR.
- **`test_escript` missing `main_module`**: the `test_escript_otp26` smoke test project lacked the `escript: [main_module: ...]` configuration in its `mix.exs` and the corresponding `cli.ex` entry point. Added both.

### Changed
- **`exec_mode` is the sole boot strategy selector**: Previously, the presence of CLI arguments could override `exec_mode`, causing daemon-configured apps to accidentally enter CLI mode (and vice versa). Now `exec_mode` is evaluated first and always respected.
- **`flatten_nested_erts` is now always applied**: even for standard releases, the flattening step is harmless (no-op when files are already flat) and essential for `include_erts: false`. The erlexec binary is moved up one level to match the kernel directory location.

### Quality
- Format: ✅ clean
- Credo --strict: ✅ 0 issues
- Compile --warnings-as-errors: ✅ 0 warnings
- Tests: 221 passing, 3 excluded (integration); 14 new tests added (6 Rust, 8 Elixir)
- Smoke tests: 7/7 passing (test_cli, test_tui, test_daemon, test_escript, test_release_otp27, test_release_nif, test_escript_otp26)

## [1.5.1] - 2026-06-10

### Added
- **Umbrella Projects Support**: New `umbrella: true` config option to build standalone binaries for umbrella sub-apps. Batamanta detects sub-apps with `batamanta:` config in `apps/`, builds releases/escripts once, and packages only configured apps.
  - `find_umbrella_apps/1` to detect sub-apps with batamanta config
  - `partition_apps_by_format/2` to split apps by release/escript format
  - `run_umbrella_release/6` to build releases for umbrella sub-apps
  - `run_umbrella_escripts/6` to build escripts for umbrella sub-apps
  - `read_umbrella_app_config/2` to read per-app batamanta configuration
  - `build_umbrella_banner/6` for umbrella-specific build banner
- **Banner images**: Six PNG banner assets added to `priv/assets/`
- **Banner fallback text**: Informational message when banner image file is not found

### Changed
- **Banner image resolution**: Expanded search candidates to include `priv/assets/` paths for both dev and prod builds
- **Host detection fallback**: Default to `:ubuntu_22_04_x86_64` when host detection fails
- **mtime_to_age_seconds/1**: Extracted duplicate datetime arithmetic into a shared helper with safe fallback for non-tuple inputs
- **Documentation**: Added comprehensive umbrella project guide in English and Spanish

### Fixed
- **Banner render with `show_banner: false`**: Removed redundant `protocol == :ascii` check that skipped banner context initialization when `show_banner` was false

### Quality
- Format: ✅ clean
- Tests: 199 passing, 3 excluded (integration); 5 new umbrella-related tests added

## [1.5.0] - 2026-05-19

### Changed
- **Development versions upgraded**: Erlang 28.1 + Elixir 1.19.5 (OTP 28)
  - Internal development now uses latest stable OTP/Elixir
  - Minimum packagable OTP remains at 25 (ERTS repository unchanged)
  - Minimum OTP to run `mix batamanta` remains at 25
- **CI matrix updated**: Elixir 1.15.8/OTP 26.2.5 + Elixir 1.19.5/OTP 28.1
- **CI caching**: Mix and Cargo dependency caching added for faster runs
- **CI artifacts**: Built binaries are now uploaded as artifacts for debugging
- **CI cleanup**: Simplified cleanup step — only clears ERTS cache, not project build artifacts

### Fixed
- **Escript wrapper args (critical)**: Arguments wrapped by the shell wrapper
  script no longer carry literal double-quote characters. `\"$arg\"` in the
  wrapper injected `"status"` (with literal quotes) instead of `status`.
  Replaced with `shift`/`set --` pattern using `"$@"` — fixes all CLI
  subcommands in escript-mode binaries.
- **Release daemon args**: Missing `-extra --` separator before user arguments
  in the daemon spawn path caused `erlexec` to interpret user args as its own
  flags. Added `-extra --` before forwarding, matching the non-daemon path.
- **Unless-else style**: Three `unless condition do :ok else ... end` blocks
  in `EscriptPackager` inverted to `if condition do ... else :ok end` (Credo
  compliance).
- **LibcDetector**: `ldd --version` detection now works on CachyOS and other
  rolling-release distributions (OTP 28 handles edge cases gracefully)
- **RustTemplate**: Removed stale P1 FIX markers; `build.rs` now panics with a
  clear error if the payload is missing instead of silently skipping
- **mix.exs**: Removed stale P2 FIX comment about `rust.test` alias
  (implementation was already correct)
- **ex_doc**: Updated from `~> 0.34` to `~> 0.40`

### Quality
- Format: ✅ clean
- Credo --strict: ✅ 0 issues (340 mods/funs)
- Compile --warnings-as-errors: ✅ 0 warnings
- Tests: 199 passing, 3 excluded (integration)

## [1.4.0] - 2026-04-07

### Added
- **Build Environment Isolation**: Introduced `Batamanta.EnvCleaner` to isolate the build process from version managers (`asdf`, `mise`, `kerl`, etc.). This ensures that the Erlang/Elixir version used for compilation matches the target ERTS, preventing "corrupt atom table" errors.
- **Shared Environment Logic**: Both Escript and Release pipelines now share a sanitized environment containing only essential system variables (`HOME`, `USER`, `TMPDIR`, `LANG`, `SHELL`, `TERM`, `SSH_AUTH_SOCK`).
- **Detailed Build Logs**: Improved error reporting for `mix release` failures by capturing and displaying the full compiler output in case of status non-zero.

### Fixed
- **Version Manager Interference**: Fixed a critical bug where `asdf` shims in the `PATH` would cause `mix` to use a different ERTS version than the one intended for packaging.
- **Legacy Elixir Compatibility**: Replaced `File.executable?/1` (introduced in Elixir 1.16) with `File.regular?/1` to maintain compatibility with Elixir 1.15.x.
- **Typo cleanup**: Corrected multiple instances of `BatmanManta` namespace typos to `Batamanta`.
- **Credo & Code Quality**: Refactored `system_paths/0` in `EnvCleaner` to reduce cyclomatic complexity and flattened nested logic in `clean_mix_build_artifacts`.

## [1.3.0] - 2026-03-25

### Added
- **Temporary Files Cleanup**: Batamanta now automatically cleans up internal temporary artifacts (`bat_cargo_cache`, `bat_pkg_*`, `bat_build_*`) after each compilation to keep `/tmp` empty while strictly preserving the ERTS cache.

### Fixed
- **Daemon Initialization Crash (Crítical / `undef`)**: Reimplemented the `spawn_detached` hook in Rust to fully inherit the parent environment (`std::env::vars()`) and properly map `argv[0]`. Fixing an elusive bug where the BEAM VM crashed on spawn in Daemon mode due to a missing environment block.
- **Daemon Logging Isolation**: `spawn_detached` no longer strictly forces a `dup2` redirect to `/dev/null` for standard file descriptors, allowing application logs to correctly print to the terminal prior to background detachment. Perfectly compatible with CI Smoke Tests.
- **Dialyzer & Compiler Specs**: Resolved compiler typing violations related to `{error, _}` on `detect_host` in `Target` and removed unused legacy branches.
- **Cleaned Test Coverage**: Updated multiple test namespaces (`Baton` -> `Batamanta`) and expanded coverage for internal functions.

## [1.2.1] - 2026-03-23

### Fixed
- **Execution Mode vs Format Nomenclature**: Corrected confusing naming - renamed `execution_mode` to `format` in configuration and documentation
- **Daemon Mode macOS Support**: Fixed daemon spawning to work on both Linux and macOS (uses `fork()` + `setsid()` via libc)
- **Banner Positioning**: Improved banner display to work consistently whether terminal is fresh or has existing output

## [1.2.0] - 2026-03-23

### Added
- **Escript Support**: New `format: :escript` option to build lightweight escripts instead of full OTP releases
- **Auto-detection**: Automatically detects escript format when project has `:escript` config in `mix.exs`
- **CLI Override**: `--format` option to override format detection from command line
- **Dynamic Version Detection**: Fixed hardcoded version `0.1.0` in Rust wrapper, now reads version from `start_erl.data`
- **Smoke Tests**: Added `test_escript` smoke test project for escript builds
- **Retry Logic for Downloads**: ERTS downloads now retry up to 3 times with exponential backoff (1s, 2s, 4s) on network failures
- **Cache Lock Mechanism**: File-based locking prevents race conditions when multiple processes try to download ERTS simultaneously
- **Improved Tar Error Parsing**: Extract-specific error messages for tar failures (permission denied, disk full, corrupted archive, etc.)
- **zstd Dependency Check**: Packager now raises a clear error with installation instructions if zstd is not found
- **Integration Tests**: New `FetcherIntegrationTest` module for tests requiring network access (excluded by default, run with `mix test --include integration`)

### Changed
- **Compilation Without --warnings-as-errors**: `EscriptBuilder` no longer fails on compiler warnings, improving build reliability across different OTP versions
- **EscriptBuilder Validation**: Improved escript validation using `File.read/1` with proper ELF/shebang magic byte detection
- **LibcDetector Refactoring**: Consolidated regex patterns for OS detection, renamed `is_musl_distro?` to `musl_distro?` for Credo compliance
- **Smaller Binaries**: Escript format produces ~60-70% smaller binaries than release format
- **EscriptPackager**: New module for packaging escripts with minimal ERTS
- **EscriptBuilder**: New module for building escripts via `mix escript.build`
- **Rust Template**: Updated to support both `:release` and `:escript` output formats via `BATAMANTA_FORMAT` env var
- **Banner Positioning**: Improved banner display to work consistently whether terminal is fresh or has existing output

### Fixed
- **Cache Race Conditions**: TOCTOU race condition in `check_erts_cache` now protected by file locks
- **Tar Error Messages**: Better error messages when tar extraction fails, including "Permission denied", "Disk full", etc.
- **Download Retry Pattern**: Fixed pattern matching to handle both `:ok` (file downloads) and `{:ok, body}` (manifest downloads) return values
- **Version Detection**: Release version is now dynamically detected from `releases/start_erl.data` instead of being hardcoded

## [1.1.0] - 2026-03-19

### Added
- **OTP Version Control**: Users can specify exact OTP versions in config (`otp_version: "28.1"`) or via CLI (`--otp-version`)
- **Explicit vs Auto Mode**: Explicit mode uses exact version (fails if unavailable), auto mode uses conservative fallback
- **Smoke Tests**: Added `test_cli`, `test_tui`, and `test_daemon` smoke test projects
- **CI Matrix**: Comprehensive CI with tests on Elixir 1.15/1.18 and OTP 25/28

### Fixed
- **MANIFEST JSON Parser**: Rewrote broken parser that incorrectly handled nested JSON structures
- **Release Path**: Fixed `get_release_path/1` to correctly use `_build/prod/rel/<app>`
- **Duplicate Logging**: Removed duplicate ERTS cached messages during build
- **Version Resolution**: Improved `generate_version_variants/1` with proper fallbacks
- **TUI Key Handling**: Fixed crash when pressing keys (handles `<<key, "\n">>` pattern)
- **Application Start**: Fixed Application behaviour to return proper `{:ok, pid}` tuple

### Changed
- `generate_version_variants/1` refactored to reduce nesting depth (Credo compliance)
- CI simplified to focus on reliable tests (removed problematic macOS ARM64 cross-compile)

## [1.0.1] - 2026-03-09

### Fixed
- **Linux auto-detection**: Automatically detects between glibc and musl based on distribution
- **Arch Linux support**: Fixed compilation on Arch-based distributions (CachyOS, Manjaro, etc.)
- **Terminal cleanup**: Improved ANSI sequence cleanup on exit
- **ERTS embedded**: Now uses the ERTS embedded in the release instead of downloading external one, fixing "Exec format error"

### Changed
- Default Linux target changed from musl to gnu for better compatibility
- Uses ctrlc instead of signal-hook for better cross-platform support

## [1.0.0] - 2026-03-16

### Added
- **Monolithic Binary Generation**: Core capability to wrap Elixir releases and the Erlang Runtime System (ERTS) into a single, static executable.
- **Dynamic ERTS Management**: Automatically fetches and caches compatible ERTS versions from Hex.pm or Beam Machine based on the target system.
- **Cross-Platform Support**: Built-in support for multiple targets including `x86_64-linux-musl`, `x86_64-pc-windows-msvc`, `x86_64-apple-darwin`, and `aarch64-apple-darwin`.
- **Rust-powered Dispenser**: A high-performance Rust wrapper that handles payload extraction, signal proxying, and secure execution.
- **Static Compilation**: Generates binaries with zero external dependencies (no Erlang or Elixir needed on the target host).
- **Binary Minification**: Integrated support for `strip` and `upx` to significantly reduce the final executable size.
- **Smart Native Fallback**: Intelligent detection to use the local native ERTS when building for the same host OS to ensure perfect compatibility.
- **Clean Task**: Provided `mix batamanta.clean` to manage and clear the local ERTS cache.
- **CLI Arg Handling**: Support for passing plain arguments directly to the Erlang VM for portable CLI tools.
- **RAII Cleanup**: Support for automatically removing temporary extraction files when the application exits.

### Improved
- **Idiomatic Refactor**: Completely refactored the codebase to use modern Elixir patterns (pipelines, pattern matching, `with` statements).
- **Documentation**: Comprehensive documentation in both English (primary) and Spanish, including detailed architecture guides and usage examples.
- **Error Handling**: Migrated to result-tuple based error propagation (`{:ok, term} | {:error, reason}`) for more reliable orchestration.
- **Unit Testing**: Full test suite covering target resolution, packaging logic, and cache management.
- **CI/CD Integration**: Pre-configured GitHub Actions to validate compatibility across multiple Elixir and OTP versions.

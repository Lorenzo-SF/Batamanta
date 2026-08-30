# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-08-30

### Added

- **CI matrix split**: a new `resolve_otp_versions` job that reads the
  upstream `Lorenzo-SF/Batamanta---ERTS-repository` `MANIFEST.json` and
  publishes `otp_min` / `otp_max` for every other job. The
  `workflow_dispatch` input now lets you override either bound, so
  the matrix stays in sync with the mirror automatically. Two matrix
  jobs follow:
    - `smoke_matrix` — a 10-cell representative subset that runs on
      every PR + push to main/develop. Covers linux-glibc-amd64
      {release × cli/tui/daemon, escript × cli}, linux-musl-amd64
      release × cli (docker alpine), linux-glibc-arm64 release × cli
      (QEMU on ubuntu-latest), darwin-arm64 {release × cli, escript × cli}
      and windows-amd64 {release × cli, escript × cli}. All cells use
  `otp_max`.
    - `nightly_full_matrix` — a 30-cell exhaustive matrix scheduled
      every Sunday 02:00 UTC. Covers both `otp_min` and `otp_max`
      for every target the Validator accepts (macos-amd64 commented
      out, requires paid runner; windows-arm64 absent — no upstream
      OTP prebuilds to mirror).
- **Step body for the build cells** maps `(format, mode)` to an
  existing `smoke_tests/` directory via the `Pick smoke_test
  directory` step. Cells without a matching test (e.g. `tui` + `escript`,
  which the validator doesn't accept on Windows) are filtered out with
  a clean skip + step summary, so the matrix never runs a cell it
  can't validate.
- **Job-level `if: matrix.runs_on == 'ubuntu-latest'` gate on
  `Install System Dependencies`** so `sudo apt-get` doesn't try to run
  on `macos-latest` (`sudo: apt-get: command not found`) or
  `windows-latest` (`sudo: command not found`).
- **`Fetcher` test (`unknown_target_atom_falls_back`)**: clarified
  that `:windows_arm64` was the old name for the test before that
  target was dropped — now titled "unknown target atom falls back
  gracefully".

### Changed

- **`@version` bumped to `2.0.0`**: both `lib/batamanta.ex` and
  `mix.exs` read the same version.
- **Toolchain pin dropped from `OTP 27.2 / Elixir 1.18.2-otp-27`
  to `OTP 26.2.5 / Elixir 1.15.8-otp-26`** in `.tool-versions` /
  `mix.exs` (`@elixir_vsn "~> 1.15"`). This is what the project is
  tested against on macOS and Cachy OS. The validator's minimum
  versions stay more permissive (`OTP 25 / Elixir 1.14`) for
  back-compat with locally-installed system ERTS.
- **MANIFEST naming aligned with upstream**:
  `priv/erts_repository/MANIFEST.json` regenerated from
  `Lorenzo-SF/Batamanta---ERTS-repository` to use the new asset key
  names (`linux-glibc-amd64`, `linux-musl-amd64`, `darwin-arm64`,
  `windows-amd64`). The previous keys (`amd64-glibc`, `amd64-musl`,
  `arm64-glibc`, `arm64-musl`) are no longer published by the upstream
  mirror — they pointed at assets that haven't existed on the release
  page since the manifest rename.
- **`manifest_compat_test.exs`**: added `latest_full_version/1` helper
  that picks the most recent OTP version in the manifest that has every
  target's `manifest_key` present. As of OTP 28.4.2 the upstream Erlang
  team dropped the prebuilt musl tarballs, so the absolute-latest
  version is no longer suitable for full-matrix coverage tests. Both
  the "every `Target.manifest_key` is present" test and the "fetcher
  resolves a real URL for each target at the latest version" test now
  use the helper.
- **`Fetcher.download_manifest/0`**: shells out to `curl` instead of
  `:httpc`. The in-VM `:httpc + :ssl + :public_key` stack was brittle
  under `Mix.Task` invocation (notably OTP 28, where `:ssl` calls
  `:public_key.cacerts_get/0` even with `verify: :verify_none`).
  `curl` is on PATH everywhere we care about (Homebrew, Git for
  Windows, system installs), ships its own cert store + retry logic,
  and the URLs we hit are pinned to our own GitHub release mirror —
  the SHA check at extraction time would catch a tampered tarball.
  See the long-form comment in `lib/batamanta/erts/fetcher.ex`
  around `download_manifest/0` for the rationale.

### Fixed

- **Cross-OS ERTS download**: running `mix batamanta` from a consumer
  (e.g. `alaja`, `zaguan`, or any project using batamanta as a
  `path:` dep) on OTP 28+ macOS/Linux no longer crashes with
  `UndefinedFunctionError: function :public_key.cacerts_get/0 is
  undefined`. The curl-based `Fetcher.download_manifest/0` is the
  single source of truth for the MANIFEST fetch.
- **Manifest validation in the ERTS mirror CI**: the
  `generate_manifest` step in
  `Lorenzo-SF/Batamanta---ERTS-repository` now uses `jq` as the
  primary validator and only falls back to `python3` when `jq` is
  missing **and** the python shim actually runs (the previous code
  treated `asdf`'s broken python3 shim — exit 126 when no
  `.tool-versions` resolves python — as a JSON validation failure,
  aborting every weekly regeneration with "JSON invalid" even though
  the JSON was fine). Regeneration no longer aborts spuriously.
- **Quality findings** caught by `mix credo --strict` on the
  `feature/8-targets-and-arm64` PR, including CRLF line endings on
  `banner.ex` / `run_script.ex`, nested-too-deep functions in
  `compression.ex` / `fetcher.ex` / `escript_packager.ex`, a
  `with`/cond refactor in `compression.ex`, and an
  `Enum.map_join/3` micro-optimisation in the manifest compat test.

### Removed

- **`priv/erts_repository/MANIFEST.json`** (314-line stale local
  fallback): the tier-3 fallback that pointed at the pre-jq-fix URL
  shape (asset URLs with a doubled `Lorenzo-SF/Lorenzo-SF/` prefix
  that the upstream mirror never published). With the upstream
  MANIFEST regenerated cleanly and the on-disk cache
  (`~/.cache/batamanta/MANIFEST.json`) covering the cold-cache case,
  the local copy was dead weight. The dispatch code in
  `Fetcher.load_manifest_from_source/0` now goes through the upstream
  / cache tiers only.

### Documented

- **`Target` moduledoc**: added a "Targets whose upstream release is
  not currently published" section noting that `:macos_12_x86_64`
  resolves via the system-installed ERTS at runtime — no
  `darwin-amd64.tar.gz` releases are currently published by the
  upstream mirror (no Mac with an Intel CPU is available in the
  maintainer's fleet to keep the build pipeline running).
- **`AGENTS.md`**: forward-looking references to Elixir `1.18` are
  now `1.15` (lines 26, 83, 222); historical "Done" notes that quote
  Elixir 1.18 behaviour (e.g. the `is_atom` warning removal) stay
  as-is — they describe what was done in past commits.
- **README.md** Compatibility Matrix updated to reflect that
  OTP 28 / Elixir 1.18 are no longer the project's primary toolchain
  (the matrix table was already correct as it lists Elixir 1.15
  and above for every OTP row).

## [1.6.1] - 2026-07-03
### Added

- **No-flatten ERTS for escript format**: escript payloads no longer
  flatten the bundled ERTS — the `erts-X.Y/` directory structure is
  kept intact and self-consistent. ERL_ROOTDIR is set in the `.run`
  script (escript case) so `erl` finds `erlexec` in the bundled ERTS.
  Boot files (`no_dot_erlang.boot`, `start.boot`) are copied to
  `release/bin/` so `erlexec` finds them. Release format unchanged
  (dyn_erl resolves ROOTDIR from its own path).
- **`.run` entry point**: New `Batamanta.RunScript` module generates a
  `.run` script at build time (Elixir side) that carries all
  environment configuration — PATH, BINDIR, neutralisation,
  `exec_mode` routing, escript/release dispatch. The Rust wrapper
  is now a minimal ~100‑line binary that only extracts the payload
  and `exec()`s the `.run` script. Changing environment variables no
  longer requires recompiling Rust.
- **`AGENTS.md` + `docs/AUDIT-rust-architecture.md`**: Architecture
  decision records documenting the re-architecture rationale,
  trade-offs, and the final payload layout.

### Fixed

- **Release-mode binaries now correctly load `sys.config` at boot**.
  The Rust wrapper was passing `--erl-config <path>` (without the
  `.config` extension), a flag the bundled `erlexec` (OTP 28.4 /
  Erlang 16.3) does not recognise. Switched to the classic
  `-config <path-to-.config>` form, which works on every erlexec
  since OTP 17. Consumer apps were silently booting with no
  application env and crashing on first Postgres/Redis/etc. access
  with errors like `missing the :database key`.
- **`RELEASE_SYS_CONFIG` double `.config` extension**: CLI release
  binaries were setting `RELEASE_SYS_CONFIG` with `.config` included.
  The Erlang `Config.Provider` machinery appends `.config`
  automatically, so it tried to read `sys.config.config` (double
  extension) and aborted boot. Fix: pass the path without `.config`
  in `RELEASE_SYS_CONFIG`, matching the standard Mix release
  `bin/app` script.
- **OTP 28+ inets lazy loading crash**: On a fresh session (no cached
  ERTS, no warm shell), `:httpc.handle_request/9` threw
  `UndefinedFunctionError` for `:http_util.timestamp/0` because
  OTP 28+ loads inets modules lazily and `:http_util` had not been
  touched yet. `ensure_started/1` now `code:ensure_loaded`s the key
  modules (`http_util`, `http_chunk`, `http_request`,
  `http_response`) before the first download request.
- **Rust wrapper cleaned up**: Removed 5 unused dependencies (sha2,
  uuid, ctrlc, md5, libc). md5 replaced with inline hash of payload
  prefix. `GENERATED_EXEC_MODE` and `GENERATED_FORMAT` removed from
  `build.rs` — all configuration now lives in the `.run` script.
  Reduced from ~435 to ~100 lines (just extract + exec).
- **`Target.detect_host_or_default/0`**: Removed dead `:error` clause
  that could never match.
- **`EscriptPackager.get_erts_version/1`**: Fixed Credo nesting
  warning.



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

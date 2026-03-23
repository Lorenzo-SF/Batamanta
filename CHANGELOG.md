# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

## [1.0.0] - 2026-03-08

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

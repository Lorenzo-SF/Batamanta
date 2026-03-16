# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

<p align="center">
  <img src="https://raw.githubusercontent.com/Lorenzo-SF/Batamanta/main/assets/batamantaman.png" width="400" alt="Batamanta Mascot" />
</p>

> Package your Elixir applications as 100% self-contained executables. No Erlang/Elixir installation required on the target machine.

---

## Features

- **Self-contained binaries**: Single executable with your app + ERTS embedded
- **Smart ERTS provisioning**: Auto-detects platform or force specific target
- **Cross-compilation**: Build for Linux (glibc/musl), macOS from any platform
- **Zstandard compression**: Optimal balance between size and speed
- **Multiple execution modes**: CLI, TUI, Daemon, and Escript support
- **Relativized releases**: Portable binaries with no absolute paths
- **Robust downloads**: Automatic retry with exponential backoff on network failures
- **Concurrent-safe caching**: File-based locking prevents race conditions in multi-process builds
- **Clear error messages**: Specific error codes for disk full, permission denied, corrupted archives

---

## Requirements

- Erlang/OTP 25+
- Elixir 1.15+
- Rust (cargo)
- Zstandard (zstd)

### Banner Dependencies (Optional)

When `show_banner: true` (default), the build process displays a banner image in the terminal. To enable full image support across all terminal emulators, install these dependencies:

#### macOS

```bash
# For Sixel support (Alacritty, Ghostty, other terminals)
brew install libsixel

# Optional: for ASCII art fallback
# img2txt is included in libsixel
```

#### Linux

```bash
# Ubuntu/Debian
sudo apt install libsixel-tools

# Arch Linux
sudo pacman -S libsixel

# Fedora
sudo dnf install libsixel
```

#### Terminal Compatibility

| Terminal | Protocol | Requires |
|----------|----------|----------|
| iTerm2 | Inline Images | Built-in |
| Ghostty | Kitty protocol | Built-in |
| WezTerm | Kitty protocol | Built-in |
| Alacritty | Kitty protocol | Built-in |
| Kitty | Kitty protocol | Built-in |
| VS Code | Sixel | `libsixel` |
| foot | Sixel | `libsixel` |
| Other terminals | ASCII fallback | None |

If no image support is detected, the banner falls back to text-only mode.

---

## Quick Start

### 1. Add Dependency

```elixir
# mix.exs
def deps do
  [{:batamanta, "~> 1.0", runtime: false}]
end
```

### 2. Configure (Auto-detect)

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    batamanta: [
      erts_target: :auto,        # Auto-detect host platform (RECOMMENDED)
      execution_mode: :cli,      # :cli | :tui | :daemon
      compression: 3,            # 1-19 (zstd level)
      binary_name: "my_app",     # Optional: custom binary name
      show_banner: true          # Optional: show build banner
    ]
  ]
end
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `erts_target` | atom | `:auto` | Target platform (see below) |
| `otp_version` | string | `:auto` | OTP version (e.g., "28.1") |
| `execution_mode` | atom | `:cli` | `:cli`, `:tui`, `:daemon`, or `:escript` |
| `compression` | integer | `3` | Zstd compression level (1-19) |
| `binary_name` | string | app name | Custom binary name |
| `show_banner` | boolean | `true` | Show build banner |
| `force_os` | string | nil | Force OS: `"linux"`, `"macos"`, `"windows"` |
| `force_arch` | string | nil | Force arch: `"x86_64"`, `"aarch64"` |
| `force_libc` | string | nil | Force libc: `"gnu"`, `"musl"` (Linux only) |

### 3. Build

```bash
mix batamanta
```

This generates: `my_app-0.1.0-x86_64-linux` (or appropriate target)

---

## ERTS Target System

Batamanta uses a unified **ERTS target** system for platform specification.

### Supported Targets

| Target Atom | OS | Arch | Libc | Use Case |
|-------------|-----|------|------|----------|
| `:auto` | - | - | - | Auto-detect host (default) |
| `:ubuntu_22_04_x86_64` | Linux | x86_64 | glibc | Debian, Ubuntu, Arch, CachyOS |
| `:ubuntu_22_04_arm64` | Linux | aarch64 | glibc | ARM servers, Raspberry Pi 4 |
| `:alpine_3_19_x86_64` | Linux | x86_64 | musl | Alpine Linux, containers |
| `:alpine_3_19_arm64` | Linux | aarch64 | musl | Alpine on ARM |
| `:macos_12_x86_64` | macOS | x86_64 | - | Intel Mac |
| `:macos_12_arm64` | macOS | aarch64 | - | Apple Silicon (M1/M2/M3) |
| `:windows_x86_64` | Windows | x86_64 | msvc | ✅ Supported |

### Manual Override

Force a specific target regardless of host:

```elixir
batamanta: [
  erts_target: :alpine_3_19_x86_64,  # Force Alpine musl
  execution_mode: :cli
]
```

Or use individual overrides:

```elixir
batamanta: [
  force_os: "linux",
  force_arch: "x86_64",
  force_libc: "musl"
]
```

### CLI Override

```bash
# Auto-detect (default)
mix batamanta

# Force specific target
mix batamanta --erts-target alpine_3_19_x86_64

# Force individual components
mix batamanta --force-os linux --force-arch aarch64 --force-libc musl
```

---

## OTP Version Control

**You specify, you own.** If you specify `otp_version`, that exact version is used. If not specified, a conservative fallback is used.

### Configuration

```elixir
# Use exact OTP version (recommended for production)
batamanta: [
  otp_version: "28.1"
]
```

### Behavior

| Mode | Description | When to Use |
|------|-------------|-------------|
| **Explicit** | Uses exact version specified. Fails if not available in repository. | Production builds, reproducibility |
| **Auto** | Uses conservative fallback (28.0 → 28.1 → ...). Uses system ERTS if not found. | Development, quick builds |

### CLI Override

```bash
# Specify exact OTP version
mix batamanta --otp-version 28.1

# Auto mode (default)
mix batamanta
```

### Version Resolution

In auto mode, if the exact version is not available:

1. Tries `OTP-28.0` first (most common)
2. Then `OTP-28.1`, `OTP-28.2`, etc.
3. Falls back to system ERTS if nothing found

---

## Execution Modes

| Mode | Description | Platform |
|------|-------------|----------|
| `:cli` | Standard CLI with inherited stdin/stdout/stderr | All |
| `:tui` | Text UI with raw terminal mode, arrow key navigation | Unix only |
| `:daemon` | Runs in background, no terminal I/O | Unix only |
| `:escript` | Standalone escript built with `mix escript.build` | All |

---

## Compatibility Matrix

### Operating Systems

| OS | Architectures | Modes | Status |
|----|---------------|-------|--------|
| **macOS 11+** | x86_64, aarch64 | CLI, TUI, Daemon | ✅ Full Support |
| **Linux (glibc)** | x86_64, aarch64 | CLI, TUI, Daemon | ✅ Full Support |
| **Linux (musl)** | x86_64, aarch64 | CLI, Daemon | ✅ Supported |
| **Windows 10+** | x86_64 | CLI | ✅ Supported |

### OTP / Elixir Versions

| OTP | Elixir | Status |
|-----|--------|--------|
| 25 | 1.15 | ✅ Minimum Supported |
| 26 | 1.15, 1.16 | ✅ Supported |
| 27 | 1.15, 1.16, 1.17 | ✅ Supported |
| 28 | 1.16, 1.17, 1.18+ | ✅ Latest |

### Restrictions

- ❌ Windows + TUI mode (requires Unix terminal)
- ❌ Windows + Daemon mode (requires Unix process management)
- ❌ OTP < 25 (missing required BEAM features)
- ❌ Elixir < 1.15 (missing required language features)

---

## Troubleshooting: Linux musl/glibc

### Problem: "libc mismatch detected" Warning

If you see a warning like:
```
⚠️  libc mismatch detected!
  Expected: glibc (Debian/Ubuntu/Arch/Fedora)
  Detected: musl libc (Alpine)
```

This means your system's libc type doesn't match the expected ERTS target.

**Solution 1: Let Batamanta auto-detect (recommended)**
```elixir
batamanta: [
  erts_target: :auto  # Auto-detects musl vs glibc
]
```

**Solution 2: Force specific target**
```elixir
batamanta: [
  erts_target: :alpine_3_19_x86_64  # Force musl
]
```

**Solution 3: Use CLI override**
```bash
mix batamanta --erts-target alpine_3_19_x86_64
```

### Problem: ERTS download fails on Alpine/musl

If ERTS download fails with 404 error on musl systems, try one of these solutions:

**Solution 1: Use auto-detection (recommended)**
```elixir
batamanta: [
  erts_target: :auto  # Auto-detects musl vs glibc
]
```

**Solution 2: Use a specific OTP version**
```elixir
batamanta: [
  otp_version: "28.0"  # Try an older version that may have musl builds
]
```

**Solution 3: Build custom ERTS for musl** (advanced)
```bash
# On Alpine Linux
apk add erlang-dev
cd /tmp
git clone https://github.com/erlang/otp.git
cd otp
./otp_build autoconf
./configure --prefix=/usr/local
make
make install
tar -czf musl-erts.tar.gz /usr/local/lib/erlang
```

### Problem: Binary doesn't run on target system

If the binary works on build machine but fails on target:

**Check libc compatibility:**
```bash
# On build machine
ldd --version

# On target machine  
ldd --version

# They should match (both glibc or both musl)
```

**Solution: Build for oldest supported glibc version**
```elixir
# Use Ubuntu 22.04 target (most compatible glibc)
batamanta: [
  erts_target: :ubuntu_22_04_x86_64
]
```

### Problem: Cross-compilation from macOS to Linux

**Install Rust targets:**
```bash
rustup target add x86_64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-gnu
```

**Build with explicit target:**
```bash
mix batamanta --erts-target ubuntu_22_04_x86_64
```

### How libc Detection Works

Batamanta uses multiple methods in order:

1. **`ldd --version`** - Most reliable, checks output for "musl" or "glibc"
2. **Dynamic loader files** - Checks `/lib/ld-musl-*.so` vs `/lib64/ld-linux-*.so`
3. **`/etc/os-release`** - Checks `ID=alpine`, `ID=void`, etc.
4. **`/proc/self/maps`** - Advanced, checks loaded libraries

Detection always falls back to glibc if uncertain (90%+ of systems use glibc).

### ERTS Download Fallback

Batamanta attempts to download pre-compiled ERTS from Hex.pm builds. If the download fails:

```
⚠️  Could not download ERTS, using system ERTS instead.
```

The build continues using the system ERTS (similar to Bakeware). This means:

- ✅ **Build succeeds** - Your application compiles
- ⚠️ **Binary requires ERTS** - Target machine needs compatible Erlang/Elixir
- ✅ **Portable within same OS** - Works on machines with same libc type

**For production self-contained binaries:**

1. Ensure network access during build
2. Use specific ERTS version: `batamanta: [otp_version: "26.2.5"]`
3. Ensure the target platform has pre-built ERTS available

---

## CLI Options

Override configuration via command line:

```bash
# Use auto-detection (default)
mix batamanta

# Force ERTS target
mix batamanta --erts-target alpine_3_19_x86_64

# Force individual components
mix batamanta --force-os linux --force-arch aarch64 --force-libc musl

# Adjust compression level
mix batamanta --compression 9

# Combine options
mix batamanta --erts-target ubuntu_22_04_arm64 --compression 5
```

### Available CLI Flags

| Flag | Description |
|------|-------------|
| `--erts-target` | Override ERTS target atom |
| `--otp-version` | Specify exact OTP version (e.g., "28.1") |
| `--force-os` | Force OS: `linux`, `macos`, `windows` |
| `--force-arch` | Force architecture: `x86_64`, `aarch64` |
| `--force-libc` | Force libc: `gnu`, `musl` (Linux only) |
| `--compression` | Zstd compression level (1-19) |

---

## For CLI Applications

Use Erlang's `:init` to read arguments:

```elixir
defmodule MyApp do
  use Application

  @impl true
  def start(_type, _args) do
    args =
      :init.get_plain_arguments()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == "--"))

    case args do
      ["hello", name] -> IO.puts("Hello, #{name}!")
      _ -> IO.puts("Usage: my_app hello <name>")
    end

    System.halt(0)
  end
end
```

Don't forget `System.halt/1` when your CLI finishes!

---

## How ERTS Provisioning Works

1. **Auto-detection**: Batamanta detects your host platform using:
   - `:os.type()` for OS identification
   - `:erlang.system_info(:system_architecture)` for architecture
   - `ldd --version` for libc detection on Linux (glibc vs musl)

2. **Download**: Fetches pre-compiled ERTS from [Hex.pm builds](https://builds.hex.pm/builds/otp/) or from the [Batamanta ERTS Repository](https://github.com/Lorenzo-SF/Batamanta---ERTS-repository)

3. **Cache**: Stores in `~/.cache/batamanta/` for reuse

4. **Package**: Bundles your release + ERTS into a single compressed tarball

5. **Compile**: Rust dispenser embeds the payload and handles extraction at runtime

---

## ERTS Repository

Batamanta uses a separate repository for pre-compiled ERTS binaries:

**[Batamanta ERTS Repository](https://github.com/Lorenzo-SF/Batamanta---ERTS-repository)**

This repository hosts pre-compiled Erlang Run-Time System (ERTS) binaries for:
- **macOS**: aarch64 (Apple Silicon)
- **Linux (glibc)**: x86_64 & aarch64
- **Linux (musl)**: x86_64 & aarch64

The binaries are compiled from official Erlang/OTP sources and are subject to the Apache License 2.0 (see the repository for details).

---

## Troubleshooting

### Linux: "ERTS not found" or wrong ERTS downloaded

Batamanta auto-detects using `ldd --version`. If this fails:

```bash
# Check what ldd reports
ldd --version

# Force specific target
mix batamanta --erts-target ubuntu_22_04_x86_64
```

### macOS: Binary doesn't run on older macOS versions

Ensure you're building with the correct deployment target:

```elixir
batamanta: [
  erts_target: :macos_12_x86_64  # or :macos_12_arm64
]
```

### Cross-compilation from macOS to Linux

Install Rust targets:

```bash
rustup target add x86_64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-gnu
```

Then build:

```bash
mix batamanta --erts-target ubuntu_22_04_x86_64
```

### Alpine/musl: "Library not found"

Ensure musl development headers are installed:

```bash
# Alpine
apk add musl-dev

# Or use the Alpine Docker image
docker run --rm -v $(pwd):/app -w /app elixir:1.18-alpine ...
```

---

## Architecture

1. **Detect**: Auto-detect or resolve manual target configuration
2. **Fetch**: Download ERTS from Hex.pm builds
3. **Release**: Compile your Elixir code with `mix release`
4. **Package**: Bundle release + ERTS with Zstd compression
5. **Compile**: Build Rust dispenser that embeds the payload
6. **Run**: Dispenser extracts payload and spawns Erlang VM

---

## Escript Support

Batamanta can package projects that use `mix escript.build` as self-contained binaries:

```elixir
def project do
  [
    app: :my_escript_app,
    version: "0.1.0",
    batamanta: [
      execution_mode: :escript,
      escript_module: MyEscriptApp.CLI  # Module with main/1 function
    ],
    escript: [
      main_module: MyEscriptApp.CLI
    ]
  ]
end
```

The project should have a module with a `main/1` function:

```elixir
defmodule MyEscriptApp.CLI do
  def main(args) do
    IO.puts("Escript running with args: #{inspect(args)}")
  end
end
```

**Note:** For escript mode, `mix.exs` should NOT include `format: :escript` - Batamanta auto-detects escript format automatically.

---

## Testing

Run the test matrix locally:

```bash
# Test across Linux distributions (requires Docker)
./docker_matrix.sh

# Run smoke tests manually
cd smoke_tests/test_cli && mix batamanta && ./test_cli-* arg1 arg2
cd smoke_tests/test_tui && mix batamanta && ./test_tui-*
cd smoke_tests/test_daemon && mix batamanta && ./test_daemon-* &
cd smoke_tests/test_escript && mix batamanta && ./test_escript --help
```

---

## License

MIT

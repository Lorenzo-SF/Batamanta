<p align="center">
  <img src="./assets/batamantaman.png" width="400" alt="Mascota Batamanta" />
</p>

> Empaqueta tus aplicaciones Elixir como ejecutables 100% autocontenidos. No requiere Erlang/Elixir en la máquina destino.

---

## Características

- **Binarios autocontenidos**: Un único archivo con tu app + ERTS incluido
- **Compilación cruzada**: Construye para Linux, macOS y Windows desde cualquier plataforma
- **Compresión Zstandard**: Óptimo equilibrio entre tamaño y velocidad
- **Múltiples modos de ejecución**: CLI, TUI y Daemon
- **Caché inteligente**: Las descargas de ERTS se almacenan localmente

---

## Requisitos

- Erlang/OTP 25+
- Elixir 1.15+
- Rust (cargo)
- Zstandard (zstd)

### Dependencias del Banner (Opcional)

Cuando `show_banner: true` (por defecto), el proceso de construcción muestra un banner con imagen en la terminal. Para habilitar el soporte completo de imágenes en todos los terminales, instala estas dependencias:

#### macOS

```bash
# Para soporte Sixel (Alacritty, Ghostty, otros terminales)
brew install libsixel

# Opcional: para fallback a ASCII art
# img2txt viene incluido en libsixel
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

#### Compatibilidad de Terminales

| Terminal | Protocolo | Requiere |
|----------|-----------|----------|
| iTerm2 | Inline Images | Incorporado |
| Ghostty | Protocolo Kitty | Incorporado |
| WezTerm | Protocolo Kitty | Incorporado |
| Alacritty | Protocolo Kitty | Incorporado |
| Kitty | Protocolo Kitty | Incorporado |
| VS Code | Sixel | `libsixel` |
| foot | Sixel | `libsixel` |
| Otros terminales | Fallback ASCII | Ninguno |

Si no se detecta soporte de imágenes, el banner usa el modo solo texto.

---

## Uso Rápido

### 1. Añadir Dependencia

```elixir
# mix.exs
def deps do
  [{:batamanta, "~> 1.0", runtime: false}]
end
```

### 2. Configurar

```elixir
def project do
  [
    app: :mi_app,
    version: "0.1.0",
    batamanta: [
      erts_target: :auto,        # Auto-detectar plataforma (RECOMENDADO)
      execution_mode: :cli,      # :cli | :tui | :daemon
      compression: 3,           # 1-19 (nivel zstd)
      binary_name: "mi_app",     # Opcional: nombre personalizado
      show_banner: true          # Opcional: mostrar banner de construcción
    ]
  ]
end
```

### Opciones de Configuración

| Opción | Tipo | Default | Descripción |
|--------|------|---------|-------------|
| `erts_target` | atom | `:auto` | Plataforma objetivo (ver abajo) |
| `execution_mode` | atom | `:cli` | `:cli`, `:tui`, o `:daemon` |
| `compression` | integer | `3` | Nivel de compresión zstd (1-19) |
| `binary_name` | string | nombre de app | Nombre personalizado del binario |
| `show_banner` | boolean | `true` | Mostrar banner de construcción |
| `force_os` | string | nil | Forzar SO: `"linux"`, `"macos"`, `"windows"` |
| `force_arch` | string | nil | Forzar arquitectura: `"x86_64"`, `"aarch64"` |
| `force_libc` | string | nil | Forzar libc: `"gnu"`, `"musl"` (solo Linux) |

**Nota para Linux**: El objetivo (glibc vs musl) se detecta automáticamente según tu distribución:
- Debian, Ubuntu, Arch, Fedora, CachyOS → usa `linux-gnu`
- Alpine Linux → usa `linux-musl`

### 3. Construir

```bash
mix batamanta
```

Esto genera: `mi_app-0.1.0-x86_64-linux`

---

## Opciones CLI

Sobrescribir configuración desde línea de comandos:

```bash
# Usar auto-detección (default)
mix batamanta

# Forzar objetivo ERTS
mix batamanta --erts-target alpine_3_19_x86_64

# Forzar componentes individuales
mix batamanta --force-os linux --force-arch aarch64 --force-libc musl

# Ajustar nivel de compresión
mix batamanta --compression 9

# Combinar opciones
mix batamanta --erts-target ubuntu_22_04_arm64 --compression 5
```

### Flags CLI Disponibles

| Flag | Descripción |
|------|-------------|
| `--erts-target` | Sobrescribir objetivo ERTS |
| `--force-os` | Forzar SO: `linux`, `macos`, `windows` |
| `--force-arch` | Forzar arquitectura: `x86_64`, `aarch64` |
| `--force-libc` | Forzar libc: `gnu`, `musl` (solo Linux) |
| `--compression` | Nivel de compresión zstd (1-19) |

---

## Modos de Ejecución

| Modo | Descripción | Plataforma |
|------|-------------|-------------|
| `:cli` | CLI estándar con stdin/stdout/stderr heredados | Todos |
| `:tui` | UI de texto con modo terminal raw, navegación con teclas de flechas | Unix only |
| `:daemon` | Ejecuta en segundo plano, sin E/S de terminal | Unix only |

---

## Para Aplicaciones CLI

Al no haber wrapper de shell, usa `:init` de Erlang para leer argumentos:

```elixir
defmodule MiApp do
  use Application

  @impl true
  def start(_type, _args) do
    args = :init.get_plain_arguments()
           |> Enum.map(&to_string/1)
           |> Enum.reject(&(&1 == "--"))
    
    case args do
      ["hola", nombre] -> IO.puts("Hola, #{nombre}!")
      _ -> IO.puts("Uso: mi_app hola <nombre>")
    end
    
    System.halt(0)
  end
end
```

¡No olvides `System.halt/1` cuando tu CLI termine!

---

## Objetivos ERTS Soportados

Batamanta usa un sistema unificado de **objetivo ERTS** para especificar la plataforma.

### Targets Soportados

| Target Atom | SO | Arq | Libc | Caso de Uso |
|-------------|-----|------|------|-------------|
| `:auto` | - | - | - | Auto-detectar host (default) |
| `:ubuntu_22_04_x86_64` | Linux | x86_64 | glibc | Debian, Ubuntu, Arch, CachyOS |
| `:ubuntu_22_04_arm64` | Linux | aarch64 | glibc | Servidores ARM, Raspberry Pi 4 |
| `:alpine_3_19_x86_64` | Linux | x86_64 | musl | Alpine Linux, contenedores |
| `:alpine_3_19_arm64` | Linux | aarch64 | musl | Alpine en ARM |
| `:macos_12_x86_64` | macOS | x86_64 | - | Mac Intel |
| `:macos_12_arm64` | macOS | aarch64 | - | Apple Silicon (M1/M2/M3) |
| `:windows_x86_64` | Windows | x86_64 | msvc | Próximamente |

### Override Manual

Fuerza un objetivo específico independientemente del host:

```elixir
batamanta: [
  erts_target: :alpine_3_19_x86_64,  # Forzar musl
  execution_mode: :cli
]
```

O usa overrides individuales:

```elixir
batamanta: [
  force_os: "linux",
  force_arch: "x86_64",
  force_libc: "musl"
]
```

**Compilación cruzada desde macOS**: Instala los targets de Rust:

```bash
rustup target add x86_64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-gnu
rustup target add x86_64-unknown-linux-musl
rustup target add aarch64-unknown-linux-musl
```

---

## Arquitectura

1. **Release**: `mix release` compila tu código
2. **Fetch**: Descarga el ERTS correspondiente a la plataforma objetivo
3. **Package**: Crea el tarball comprimido (release + ERTS)
4. **Compile**: El dispenser de Rust embeber el payload
5. **Run**: El dispenser extrae el payload y lanza la VM de Erlang

---

## Repositorio de ERTS

Batamanta usa un repositorio separado para binarios ERTS precompilados:

**[Batamanta ERTS Repository](https://github.com/Lorenzo-SF/Batamanta---ERTS-repository)**

Este repositorio aloja binarios ERTS precompilados para:
- **macOS**: aarch64 (Apple Silicon)
- **Linux (glibc)**: x86_64 & aarch64
- **Linux (musl)**: x86_64 & aarch64

Los binarios están compilados desde las fuentes oficiales de Erlang/OTP y están sujetos a la Licencia Apache 2.0 (consulta el repositorio para más detalles).

---

## Licencia

MIT

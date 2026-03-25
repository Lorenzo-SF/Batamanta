<p align="center">
  <img src="https://raw.githubusercontent.com/Lorenzo-SF/Batamanta/main/assets/batamantaman.png" width="400" alt="Mascota Batamanta" />
</p>

> Empaqueta tus aplicaciones Elixir como ejecutables 100% autocontenidos. No requiere Erlang/Elixir en la máquina destino.

---

## Características

- **Binarios autocontenidos**: Un único archivo con tu app + ERTS incluido
- **Compilación cruzada**: Construye para Linux, macOS y Windows desde cualquier plataforma
- **Compresión Zstandard**: Óptimo equilibrio entre tamaño y velocidad
- **Formatos Versátiles**: Soporte para `:release` (completo) y `:escript` (ligero)
- **Limpieza Automática**: Borra temporales de construcción tras éxito, manteniendo el sistema limpio pero preservando la caché de ERTS
- **Caché Inteligente**: Descargas de ERTS locales con bloqueos para evitar condiciones de carrera en compilaciones concurrentes

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
| `otp_version` | string | `:auto` | Versión OTP (ej: "28.1") |
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

---

## Formatos de Salida

Batamanta soporta dos formatos de salida:

### `:release` (Default)

Genera un release completo de OTP con supervisor tree. Ideal para:
- Servicios y aplicaciones de larga duración
- Aplicaciones que necesitan supervisión OTP completa
- Distribuciones Erlang

```elixir
batamanta: [
  format: :release
]
```

### `:escript`

Genera un escript ligero con runtime de Elixir embebido. Ideal para:
- Herramientas CLI
- Proyectos que ya usan `mix escript.build`
- **Binarios autocontenidos**: Embebe un ERTS ligero y no requiere Erlang en el host
- Binarios pequeños (~60-70% más pequeños)

```elixir
batamanta: [
  format: :escript
]
```

**Detección automática**: Si tu proyecto tiene configuración `:escript` en `mix.exs`, batamanta usará automáticamente el formato `:escript`.

### Comparación

| Aspecto | `:release` | `:escript` |
|---------|------------|------------|
| Tamaño | ~80-150 MB | ~15-30 MB |
| Startup | Lento | Rápido |
| Supervisor Tree | ✅ Completo | ❌ No disponible |
| Daemon Mode | ✅ | ❌ |
| Hot Upgrades | ✅ | ❌ |
| Elixir embebido | No | ✅ |

### CLI Override

```bash
# Forzar formato escript
mix batamanta --format escript

# Forzar formato release
mix batamanta --format release
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
| `--otp-version` | Versión OTP exacta (ej: "28.1") |
| `--force-os` | Forzar SO: `linux`, `macos`, `windows` |
| `--force-arch` | Forzar arquitectura: `x86_64`, `aarch64` |
| `--force-libc` | Forzar libc: `gnu`, `musl` (solo Linux) |
| `--compression` | Nivel de compresión zstd (1-19) |

---

## Control de Versión OTP

**Tú especificas, tú respondes.** Si especificas `otp_version`, se usa esa versión exacta. Si no se especifica, se usa un fallback conservador.

### Configuración

```elixir
# Usar versión OTP exacta (recomendado para producción)
batamanta: [
  otp_version: "28.1"
]
```

### Comportamiento

| Modo | Descripción | Cuándo Usarlo |
|------|-------------|---------------|
| **Explícito** | Usa la versión exacta. Falla si no está disponible en el repositorio. | Producción, reproducibilidad |
| **Auto** | Usa fallback conservador (28.0 → 28.1 → ...). Usa ERTS del sistema si no encuentra nada. | Desarrollo, builds rápidos |

### CLI

```bash
# Especificar versión OTP exacta
mix batamanta --otp-version 28.1

# Modo auto (por defecto)
mix batamanta
```

### Resolución de Versión

En modo auto, si la versión exacta no está disponible:

1. Prueba `OTP-28.0` primero (más común)
2. Luego `OTP-28.1`, `OTP-28.2`, etc.
3. Hace fallback al ERTS del sistema si no encuentra nada

---

## Modos de Ejecución

| Modo | Descripción | Plataforma |
|------|-------------|-------------|
| `:cli` | CLI estándar con stdin/stdout/stderr heredados | Todos |
| `:tui` | UI de texto con modo terminal raw, navegación con teclas de flechas | Unix only |
| `:daemon` | Ejecuta en segundo plano, sin E/S de terminal | Unix only |

---

## Compatibilidad de Plataformas

### Sistemas Operativos

| SO | Arquitecturas | Modos | Estado |
|----|---------------|-------|--------|
| **macOS 11+** | x86_64, aarch64 | CLI, TUI, Daemon | ✅ Soporte Completo |
| **Linux (glibc)** | x86_64, aarch64 | CLI, TUI, Daemon | ✅ Soporte Completo |
| **Linux (musl)** | x86_64, aarch64 | CLI, Daemon | ✅ Soportado |
| **Windows 10+** | x86_64 | CLI | ✅ Soportado |

### Restricciones

- ❌ Windows + modo TUI (requiere terminal Unix)
- ❌ Windows + modo Daemon (requiere gestión de procesos Unix)
- ❌ OTP < 25 (funciones BEAM requeridas no disponibles)
- ❌ Elixir < 1.15 (funciones del lenguaje requeridas no disponibles)

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
| `:windows_x86_64` | Windows | x86_64 | msvc | ✅ Soportado |

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

## Solución de Problemas: Linux musl/glibc

### Problema: Advertencia "libc mismatch detected"

Si ves una advertencia como:
```
⚠️  libc mismatch detected!
  Expected: glibc (Debian/Ubuntu/Arch/Fedora)
  Detected: musl libc (Alpine)
```

Esto significa que el tipo libc de tu sistema no coincide con el objetivo ERTS esperado.

**Solución 1: Dejar que Batamanta auto-detecte (recomendado)**
```elixir
batamanta: [
  erts_target: :auto  # Auto-detecta musl vs glibc
]
```

**Solución 2: Forzar objetivo específico**
```elixir
batamanta: [
  erts_target: :alpine_3_19_x86_64  # Forzar musl
]
```

**Solución 3: Usar override CLI**
```bash
mix batamanta --erts-target alpine_3_19_x86_64
```

### Problema: La descarga de ERTS falla en Alpine/musl

Si la descarga de ERTS falla con error 404 en sistemas musl:

**Solución 1: Usar auto-detección (recomendado)**
```elixir
batamanta: [
  erts_target: :auto  # Auto-detecta musl vs glibc
]
```

**Solución 2: Usar una versión OTP específica**
```elixir
batamanta: [
  otp_version: "28.0"  # Probar una versión anterior con builds musl
]
```

### Problema: El binario no funciona en el sistema destino

**Verifica compatibilidad libc:**
```bash
# En máquina de construcción
ldd --version

# En máquina destino  
ldd --version

# Ambos deben coincidir (glibc o musl)
```

**Solución: Construir para glibc más antiguo**
```elixir
# Usar objetivo Ubuntu 22.04 (glibc más compatible)
batamanta: [
  erts_target: :ubuntu_22_04_x86_64
]
```

### Cómo funciona la Detección de libc

Batamanta usa múltiples métodos en orden:

1. **`ldd --version`** - Más confiable, busca "musl" o "glibc" en la salida
2. **Archivos de dynamic loader** - Busca `/lib/ld-musl-*.so` vs `/lib64/ld-linux-*.so`
3. **`/etc/os-release`** - Busca `ID=alpine`, `ID=void`, etc.
4. **`/proc/self/maps`** - Avanzado, verifica librerías cargadas

La detección siempre hace fallback a glibc si hay incertidumbre (90%+ de sistemas usan glibc).

### Fallback de Descarga de ERTS

Batamanta intenta descargar ERTS pre-compilados de Hex.pm builds. Si la descarga falla:

```
⚠️  Could not download ERTS, using system ERTS instead.
```

El build continúa usando el ERTS del sistema. Esto significa:

- ✅ **Build exitoso** - Tu aplicación compila
- ⚠️ **Binario requiere ERTS** - La máquina destino necesita Erlang/Elixir compatible
- ✅ **Portable dentro del mismo SO** - Funciona en máquinas con el mismo tipo libc

**Para binarios autocontenidos de producción:**

1. Asegura acceso a red durante el build
2. Usa versión ERTS específica: `batamanta: [otp_version: "26.2.5"]`
3. Asegura que la plataforma objetivo tenga ERTS pre-compilados disponibles

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

## Testing

Ejecuta la matriz de tests localmente:

```bash
# Probar en diferentes distribuciones Linux (requiere Docker)
./docker_matrix.sh

# Ejecutar smoke tests manualmente
cd smoke_tests/test_cli && mix batamanta && ./test_cli-* arg1 arg2
cd smoke_tests/test_tui && mix batamanta && ./test_tui-*
cd smoke_tests/test_daemon && mix batamanta && ./test_daemon-* &
```

---

## Licencia

MIT

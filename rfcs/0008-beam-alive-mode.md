# RFC-0008: BEAM Alive Mode para Batamanta

| Campo          | Valor                                            |
|----------------|--------------------------------------------------|
| **Estado**     | Aceptado                                         |
| **Autor**      | arquitecto (RFC emitido para revisión)           |
| **Ticket**     | T-008                                            |
| **Propietario**| Lorenzo-SF (`lorenzo-sf`)                        |
| **Proyecto**   | `/home/merendandum/cacafuti/batamanta`           |
| **Versión obj.**| 1.7.0 (minor bump por nueva capacidad opcional)  |
| **Stack**      | Elixir 1.15+ / OTP 25–28 / Rust 1.74+ (edition 2021) |
| **Plataformas**| Linux glibc, Linux musl, macOS (sin Windows)     |

## Decisiones finales (resueltas 2026-07-07)

| Pregunta | Decisión |
|----------|----------|
| OQ-1: Timeout para lock stale | **30 s**, ajustable por env var `BATAMANTA_LOCK_TIMEOUT_MS`. |
| OQ-2: Concurrencia del keeper | **FIFO/1** sobre BEAM compartida. Refuerzos: (a) timeout por request en el runner vía `BATAMANTA_REQUEST_TIMEOUT_MS` (default 60 s); (b) la app del usuario corre dentro de un `spawn_monitor` para que un crash suyo no tumbe el BEAM keeper. |
| OQ-3: Ctrl+C durante startup | **Opción B refinada**: el wrapper hace `fork()` sin `setsid()`/sin `setpgid()` (el child hereda el process group del wrapper). Handlers de `SIGINT`/`SIGTERM`/`SIGHUP` hacen `killpg(getpgrp(), sig)`. Coste: 1 syscall por handler. Sin race en startup. |
| OQ-4: Path del socket | **`XDG_RUNTIME_DIR` si existe**, fallback a `/tmp`. Wrapper mira `env::var("XDG_RUNTIME_DIR")` primero. |
| OQ-5: TTL por proyecto | Cada binario **bakea el nombre del env var** (`beam_alive: [var: "..."]`). Diferenciar proyectos = elegir nombres distintos (o el mismo si se quiere controlarlos juntos). Defaults por proyecto. |
| Hot reload | **Fuera de scope por diseño.** Batamanta es la etapa final del dev process — el binario es la frontera entre "en desarrollo" y "en producción". Recompilar produce un nuevo UUID; convivirá con el viejo durante su TTL. |

## Resumen

Este RFC introduce un **modo opcional de mantener la BEAM viva** entre invocaciones
sucesivas de un binario Batamanta, evitando el coste de arranque repetido de la VM y
de las aplicaciones OTP del usuario (típicamente 50–400 ms por invocación en
proyectos reales, hasta varios segundos con `mix release` pesado).

La característica se activa con una combinación build-time + runtime:

- **Build time** (`mix.exs`): `batamanta: [beam_alive: [enabled: true, ...]]` — bakes
  en el binario la capacidad de actuar como keeper, el nombre del env var, y un TTL
  por defecto.
- **Runtime** (env var): si el env var está set a un entero positivo N, la VM queda
  viva N ms tras la última petición. Si está unset/vacío/`"0"`, comportamiento
  idéntico al actual (single-shot).

Cada binario lleva un **UUID v4 bakeado en `build.rs`**, lo que garantiza
identificación inequívoca entre binarios distintos, incluso si comparten payload. El
directorio runtime pasa de `/tmp/batamanta_<app>_<hash8>/` a
`/tmp/batamanta-<UUID>/`, donde residen el socket Unix, el PID file, y el lock dir
que serializa el arranque.

El mecanismo de comunicación entre el wrapper (cliente) y la BEAM persistente
(keeper) es **Unix domain socket con protocolo línea-a-línea** (request) +
**longitud-prefijado** (response). El keeper es una aplicación Erlang de 5 módulos
que se compila con `elixirc` en build time, se embebe en
`release/lib/batamanta_keeper-0.1.0/ebin/`, y arranca las apps del usuario dentro
de la misma BEAM usando `application:ensure_all_started/1` / `application:stop/1`.

El diseño garantiza **aislamiento total** entre binarios Batamanta distintos:
ningún recurso (socket, lock, BEAM, ETS) se comparte entre dos UUIDs.

## Motivación

### Coste medible de arranque

En proyectos Elixir/OTP típicos, una invocación `mix release` arranca:

1. `erlexec` (C): ~5–15 ms.
2. Boot script `start.boot`: ~30–80 ms (kernel, stdlib, sasl).
3. Apps del usuario: ~50–300 ms (config, supervisor tree, conexiones).
4. Compilación lazy de módulos: variable, puede sumar 100+ ms en frío.

Para herramientas CLI invocadas en bucles (linters, formatters, runners de tests,
scripts de CI, REPLs efímeros), ese coste se paga en cada llamada. `delfos` (el
consumidor principal declarado en `AGENTS.md`) ejecuta `delfos doctor` y comandos
similares decenas de veces por sesión de desarrollo.

### Casos de uso

- **CLI tools en TUI/REPL** — `iex`-like con arranque < 50 ms.
- **CI pipelines** que invocan el mismo bin N veces — ahorro acumulativo.
- **Wrappers de comandos** estilo `git` donde cada `batamanta-foo subcmd` paga
  arranque.
- **Dev loops** con watcher externo (no es el caso por ahora, pero habilita futuro).

### Casos donde NO aplica (y debe seguir sin aplicar)

- Daemons (`:execution_mode: :daemon`) — ya tienen ciclo de vida largo.
- TUIs interactivos largos — la sesión es la unidad, no la invocación.
- Binarios donde el usuario NO setea el env var — comportamiento idéntico al actual.

### Por qué no estaba ya (objeciones respondidas)

- **Complejidad operacional**: mantenemos binarios legacy sin cambios; la feature
  es opt-in y se puede hacer A/B sin recompilar.
- **Aislamiento entre proyectos**: el UUID bakeado cierra el problema (ver §"Aislamiento").
- **Depuración**: el keeper es trazable; se puede correr con `BEAM_ALIVE=0` para
  forzar el path legacy.
- **Tamaño del binario**: el keeper añade ~80 KB de `.beam` comprimidos — despreciable.

## Diseño propuesto

### Vista general (diagrama de componentes)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  HOST MACHINE                                                                │
│                                                                              │
│  Invocación 1                  Invocación 2 (T+200ms, dentro de TTL)         │
│  ┌─────────────────┐          ┌─────────────────┐                            │
│  │ wrapper (Rust)  │          │ wrapper (Rust)  │                            │
│  │ - extract        │          │ - extract (skip)│                            │
│  │ - read env var   │          │ - connect sock  │                            │
│  │ - mkdir lock_dir │          │ - send REQ      │                            │
│  │ - spawn BEAM     │          │ - read RSP      │                            │
│  │ - connect sock   │          │ - exit 0        │                            │
│  │ - send REQ       │          └────────┬────────┘                            │
│  │ - read RSP       │                   │                                     │
│  │ - exit 0         │                   ▼                                     │
│  └────────┬─────────┘          ┌────────────────────┐                         │
│           │                    │ /tmp/batamanta-<UUID>/                       │
│           ▼                    │   ├── keeper.sock  (AF_UNIX, 0700)            │
│  ┌─────────────────┐          │   ├── keeper.pid  (text)                     │
│  │  fork+exec      │          │   ├── lock/       (placeholder)              │
│  │  erlexec keeper │          │   └── release/    (payload extraído)         │
│  └────────┬────────┘          │       └── ...      (BEAM + app del usuario)  │
│           │                    └─────────┬──────────┘                        │
│           ▼                              │                                   │
│  ┌──────────────────────────────────────▼──────────────────────────────┐   │
│  │ BEAM (UUID = X, PID = Y)                                              │   │
│  │   ├── batamanta_keeper_sup                                            │   │
│  │   │   └── batamanta_keeper_server (gen_server)                        │   │
│  │   │       ├── gen_tcp listen AF_UNIX                                   │   │
│  │   │       ├── inactivity_timer (ETS-backed counter)                   │   │
│  │   │       └── app_state (running | stopped)                           │   │
│  │   ├── user_apps (application:ensure_all_started → up)                  │   │
│  │   │   ├── :kernel, :stdlib, :sasl                                     │   │
│  │   │   └── <app del usuario>                                            │   │
│  │   └── ETS/ports/process_dictionary (del usuario, vivos)                │   │
│  └───────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Configuración

```elixir
# mix.exs (proyecto consumidor)
def project do
  [
    app: :my_cli,
    version: "0.1.0",
    batamanta: [
      # ... config existente ...
      beam_alive: [
        enabled: true,                          # bakea capacidad en el binario
        var: "MY_CLI_BEAM_ALIVE",               # nombre del env var
        default_ms: 0                          # si el env var no está: feature off
      ]
    ]
  ]
end
```

**Resolución de opciones A vs B vs C** (decisión C):

| Opción | Cómo se activa | Pros | Contras | Veredicto |
|--------|----------------|------|---------|-----------|
| A: bake-time (`BEAM_ALIVE_TIME=30000` en config) | Solo compilando | Simple, una sola fuente de verdad | Cambiar TTL requiere recompilar. Tests en CI lentos (recompilación por experimento). | ❌ |
| B: env var descubierta (`BATAMANTA_BEAM_ALIVE`) | Runtime | Flexible, ideal para CI/dev loops | Nombre fijo; si dos proyectos coexisten en mismo shell, colisión. Sin default. | ❌ |
| **C: nombre baked + valor runtime** (elegida) | Build: nombre y default. Runtime: valor entero. | Single binary, multi-modo, naming por proyecto/cuenta, default opcional, backward compatible | Una capa de indirección (hay que mirar dos sitios) | ✅ |

**Semántica runtime** (en `priv/rust_template/src/main.rs`):

```
Casos:
  enabled: false en build           → comportamiento legacy SIEMPRE
  enabled: true,  var unset/""/0    → comportamiento legacy
  enabled: true,  var = "N" (N>0)   → alive mode, TTL = N ms
  enabled: true,  var = inválido    → comportamiento legacy + warning a stderr
```

**Backward compatibility (clave)**: cualquier binario compilado sin `beam_alive:` o
con `enabled: false` no lleva el env var, no lleva la tabla de config en
`generated_config.rs` (o la lleva con `enabled: false`), y el wrapper ni siquiera
mira el env var. Coste runtime: una comparación de un `bool` estático.

### Identificación única: UUID v4 bakeado

**Problema actual** (en `priv/rust_template/src/main.rs:21-25`):

```rust
let prefix: String = bytes[..8.min(bytes.len())]
    .iter()
    .map(|b| format!("{:02x}", b))
    .collect();
let extract_dir = env::temp_dir().join(format!("batamanta_{}_{}", GENERATED_APP_NAME, prefix));
```

- El "prefix" son los primeros 8 bytes del payload `.tar.zst`. **No es estable**:
  zstd mete headers con timestamps, lo que cambia con cada build aunque el
  contenido lógico sea idéntico.
- **No es único**: dos binarios con el mismo payload (e.g. mismo `:my_app` 0.1.0
  compilado en CI y descargado por dos usuarios) colisionan en `/tmp`.
- **Filtra información del payload**: los primeros bytes son zstd header, leakea
  estructura.

**Decisión**: en `priv/rust_template/build.rs`, generar un `Uuid::new_v4()` y
emitirlo como constante `pub const GENERATED_INSTANCE_ID: &str = "..."` en
`generated_config.rs`. Coste: una llamada a `rand::thread_rng()` durante `cargo
build`. UUID es RFC 4122 v4 (122 bits de entropía) — colisión astronómicamente
improbable.

```rust
// priv/rust_template/build.rs (nuevo)
use uuid::Uuid;

fn main() {
    let instance_id = Uuid::new_v4().to_string();
    // ... escribir generated_config.rs con GENERATED_INSTANCE_ID ...
}
```

**Implicaciones**:
- Path runtime: `/tmp/batamanta-<UUID>/` (sin app name, sin hash) — más limpio.
- El `app_name` se mantiene como `GENERATED_APP_NAME` para construir el path al
  script `.run` y al binario del release dentro de `release/bin/`.
- Compatible con el patrón `smoke_tests.sh` que hace `rm -fr /tmp/batamant*`.

**Por qué UUID y no hash de payload estable**: aunque podemos hashear el payload de
forma estable, eso filtra información sobre la build (mismos bytes → mismo
producto, lo cual puede ser deseable para reproducibilidad pero no para
aislamiento entre cuentas de CI). UUID es la opción estándar.

### Estructura del payload con feature activada

```
/tmp/batamanta-<UUID>/
├── keeper.sock                  # AF_UNIX, perms 0700
├── keeper.pid                   # texto ASCII: "<pid>\n"
├── lock/                        # placeholder; existencia = "startup en curso"
├── started_at                   # epoch ms en que arrancó el keeper
└── release/
    ├── bin/<app>                # script del release (sin cambios)
    ├── bin/<app>.run            # entry point legacy (sin cambios)
    ├── bin/erl                  # del ERTS
    ├── bin/escript              # del ERTS
    ├── bin/start.boot           # del release
    ├── erts-<v>/bin/erlexec     # VM
    ├── erts-<v>/bin/beam.smp    # emulador
    ├── lib/kernel-*, stdlib-*   # del ERTS
    ├── lib/<app>-<vsn>/         # app del usuario
    ├── lib/batamanta_keeper-0.1.0/   # ← NUEVO
    │   ├── ebin/batamanta_keeper_*.beam
    │   └── ebin/batamanta_keeper.app
    └── releases/<vsn>/          # boot scripts + sys.config + vm.args
```

**Con feature desactivada**: estructura idéntica a la actual, sin
`lib/batamanta_keeper-0.1.0/`. El wrapper ni siquiera intenta el path alive.

### Módulos a crear/modificar

#### Elixir — nuevos

| Path | Rol | LOC est. |
|------|-----|----------|
| `lib/batamanta/keeper.ex` | Compilador del keeper. Lee `priv/keeper/`, invoca `elixirc` del host, deposita `.beam` en staging dir. Invocado desde `Packager` / `EscriptPackager` cuando `beam_alive.enabled: true`. | ~120 |
| `lib/batamanta/keeper_config.ex` | Normaliza y valida el bloque `beam_alive:` del mix config. Genera el struct `t()` con `enabled`, `var`, `default_ms`. | ~60 |
| `lib/batamanta/keeper_launcher.ex` | Genera el comando `erlexec` con los args correctos para arrancar la BEAM con código del keeper cargado y la app del usuario **NO** autoarrancada. Inyecta el UUID y el TTL inicial vía env vars. | ~80 |
| `test/batamanta/keeper_config_test.exs` | Tests del normalizador. | ~40 |
| `test/batamanta/keeper_compile_test.exs` | Tests del compilador (mockeando `elixirc`). | ~60 |

#### Erlang — nuevos (en `priv/keeper/src/`)

| Path | Rol | LOC est. |
|------|-----|----------|
| `priv/keeper/src/batamanta_keeper_app.erl` | OTP `application` callback. Lee env vars `BATAMANTA_INSTANCE_ID`, `BATAMANTA_INITIAL_TTL_MS`. Arranca el supervisor. | ~40 |
| `priv/keeper/src/batamanta_keeper_sup.erl` | Supervisor `one_for_one` del server. | ~25 |
| `priv/keeper/src/batamanta_keeper_server.erl` | `gen_server` con `gen_tcp:listen/2` en `AF_UNIX`. Acepta connections, las entrega al runner. Mantiene el inactivity_timer. | ~180 |
| `priv/keeper/src/batamanta_keeper_protocol.erl` | Encode/decode del protocolo línea-a-línea (request) y longitud-prefijado (response). | ~120 |
| `priv/keeper/src/batamanta_keeper_runner.erl` | Ejecuta una request: `application:load/1` + `application:ensure_all_started/1` para la app del usuario, espera a que termine el main, captura `IO` group_leader, devuelve resultado. Limpia state entre requests. | ~200 |
| `priv/keeper/src/batamanta_keeper.app.src` | `application` resource file. `{application, batamanta_keeper, [{env, [...]}, {modules, [...]}, {registered, [...]}]}`. | ~20 |
| `priv/keeper/src/batamanta_keeper.app` | (generado en build) | — |

Total Erlang: ~585 líneas, todas triviales (no negocian HTTP, no gestionan
clusters, no parsean configs complejas).

#### Elixir — modificados

| Path | Cambio |
|------|--------|
| `lib/batamanta/packager.ex` | Tras `get_erts_version/1` y antes de `collect_files/4`: si `beam_alive.enabled`, llamar a `Batamanta.Keeper.compile/2` para producir los `.beam`, depositarlos en `rel_path/lib/batamanta_keeper-0.1.0/ebin/`. La función recibe `rel_path` (staging) y `erts_path` (para usar el `elixirc` correcto). Sin cambios en el resto del flow. |
| `lib/batamanta/escript_packager.ex` | Idem, pero el staging dir es el temp escript, no el release. |
| `lib/batamanta/rust_template.ex` | Pasar `bata_config` ya parseado (no el raw) a `compile_rust/5`. Emitir nuevas env vars: `BATAMANTA_BEAM_ALIVE_ENABLED=1` (o `=0`), `BATAMANTA_BEAM_ALIVE_VAR=<nombre>`, `BATAMANTA_BEAM_ALIVE_DEFAULT_MS=<n>`. |
| `lib/mix/tasks/batamanta.ex` | Al construir el release, pasar `keeper_opts` a ambos packagers. Validar config con `Batamanta.KeeperConfig.validate!/1` antes de fetch de ERTS (fail fast). |
| `lib/batamanta/validator.ex` | Añadir validación de `beam_alive: [enabled: true]` vs OTP < 25 → raise. (Mínimo OTP se mantiene en 25; la feature no requiere nada nuevo.) |
| `lib/batamanta/run_script.ex` | Sin cambios en el path legacy. En el path alive, el wrapper NO invoca el `.run`; el keeper arranca la app directamente. Esto significa que `.run` se queda como artefacto para la rama legacy. Si `enabled: false`, el `.run` no se necesita en absoluto (cambio menor: skip en packager cuando no hay feature). |

#### Rust — modificados/nuevos

| Path | Cambio | LOC est. |
|------|--------|----------|
| `priv/rust_template/src/main.rs` | Reescrito: extracción + lectura del flag baked `BEAM_ALIVE_ENABLED` + lectura del env var (con default baked) + branch (legacy vs alive) + (alive) mkdir lock, spawn keeper, connect sock, send req, read rsp, propagate exit. | ~210 (era ~100, +110) |
| `priv/rust_template/src/ipc.rs` | **Nuevo**. Lógica de cliente Unix socket: connect, send línea-a-línea, read longitud-prefijado, helper de signal forwarding. | ~150 |
| `priv/rust_template/src/signal.rs` | **Nuevo**. Wrapper sobre `nix::sys::signal` para SIGINT/SIGTERM/SIGHUP → `kill(keeper_pid, signal)` o enviar `SIGNAL <name>` por socket. | ~50 |
| `priv/rust_template/src/lockfile.rs` | **Nuevo**. `mkdir(2)` atómico con manejo de `EEXIST` + `kill -0` para distinguir lock vivo vs stale. | ~80 |
| `priv/rust_template/build.rs` | Añade `Uuid::new_v4()` → `GENERATED_INSTANCE_ID`. Lee nuevas env vars `BATAMANTA_BEAM_ALIVE_*` y las serializa a `generated_config.rs`. | ~30 (era ~39) |
| `priv/rust_template/Cargo.toml` | Suma `uuid = { version = "1", features = ["v4"] }`. Re-suma `nix` (ya estaba, queda). Suma `signal-hook` o usa `nix::sys::signal` (ya en deps vía nix). | +1 dep |
| `priv/rust_template/Cargo.lock` | Limpiar deps muertas (uuid, ctrlc, libc, md5, sha2, tempfile están listadas pero no usadas en `Cargo.toml` actual — esto es drift, se limpia en este RFC). | — |

**Tensión con AGENTS.md** (línea 8): *"El wrapper NO debe reimplementar lógica de boot — solo extraer payload y exec el script `.run`"*.

**Resolución**: el wrapper añade ~110 líneas que son **lógica de dispatch** (cliente
IPC), no **lógica de boot** (PATH/BINDIR/neutralización/version managers, que
siguen siendo del `.run` y se invocan igual en el path legacy). La filosofía se
preserva: el wrapper no sabe nada de Erlang, de boot scripts, de release.config,
ni de versiones de OTP. Solo sabe "extraer, hablar con un socket local si existe,
si no crear uno y arrancarlo". La distinción "boot vs dispatch" es la línea
divisoria que el RFC mantiene.

Si en el futuro el wrapper crece más, se reconsidera (ver §"Trabajo futuro").

### Protocolo de comunicación

#### Canales

- **Unix domain socket** (`AF_UNIX`, `SOCK_STREAM`) en
  `/tmp/batamanta-<UUID>/keeper.sock`.
- Permisos: `0700` en el directorio padre; socket creado con `umask 0077` o
  `fchown(0, 0)` antes de bind. Ver §"Seguridad".
- Conexión persistente por request: el cliente abre, escribe la request, lee la
  response, cierra. (No hay multiplexing dentro de una conexión — simplicidad.)

#### Request (cliente → keeper)

Línea-a-línea, terminadas en `\n`. No UTF-8 estricto: bytes arbitrarios en
`STDIN_BEGIN`/`STDIN_END` se manejan con un preámbulo de longitud en la
línea previa.

```
HELLO\n                            ← opcional, handshake inicial
REQ\n
arg_count=<N>\n
<arg0>\n
<arg1>\n
...
<argN-1>\n
env_count=<M>\n
KEY=VALUE\n
KEY2=VALUE2\n
...
STDIN_BEGIN
<stdin raw bytes>
STDIN_END\n
ttl_reset_ms=<M2>\n               ← opcional: si el cliente quiere extender TTL
```

Notas:
- `<argK>` se asume UTF-8. Si el usuario mete bytes no-UTF-8 en argv, el keeper
  los rechaza con `RSP error=invalid_arg_encoding`. (Razonable: argv del SO es
  bytes, pero Erlang maneja binaries; exigimos UTF-8 por simplicidad. Trade-off
  documentado en §"Limitaciones conocidas".)
- `<KEY=VALUE>` se parsea con `:lists.splitwith(fun(C) -> C =/= $= end, Line)`.
  Valores con `\n` embedded **no permitidos** (un env var por línea). Si el
  usuario necesita eso, usa un canal distinto.
- `STDIN_BEGIN`/`STDIN_END` delimitan el payload. El wrapper calcula el byte
  count y lo emite como línea previa: `STDIN_BEGIN <byte_count>\n`. (Decisión:
  usar longitud explícita en lugar de EOF marker para que el keeper no tenga que
  hacer shutdown(SHUT_WR) del lado del cliente.)

#### Response (keeper → cliente)

Longitud-prefijado, para evitar ambigüedad con bytes arbitrarios en stdout/stderr:

```
RSP\n
exit_code=<N>\n
stdout_len=<K>\n
<K raw bytes>
stderr_len=<J>\n
<J raw bytes>
```

- Si `exit_code < 0` o `>= 256`: error de protocolo. El cliente imprime
  "internal keeper error" a stderr y sale con código 70 (`EX_SOFTWARE`).
- Si la respuesta es `RSP error=<reason>\n`, es un rechazo de protocolo. El
  cliente lo trata como error fatal.

#### Handshake inicial (opcional pero recomendado)

```
C: HELLO\n
S: HELLO_RSP alive_ms=<remaining>\n
```

El cliente aprende el TTL real restante (por si hubo drift entre el env var y el
keeper). Útil para diagnóstico y para el caso en que el cliente quiera extender el
TTL en la request: `ttl_reset_ms=<M2>` le dice al keeper "extiende el TTL a
M2 ms desde ahora".

Si el cliente no envía HELLO, el keeper asume `alive_ms = initial_ttl_ms` y opera
normal. La primera request REQ hace el HELLO implícitamente.

#### Bytes máximos

- Request: 64 KB hard cap (suficiente para argv/env de cualquier uso real).
- Response: 64 MB hard cap (suficiente para `mix format` y similares).
- Si se excede: keeper mata la app del usuario, cierra socket, responde
  `RSP error=response_too_large`. Cliente imprime a stderr y exit 1.

### Aislamiento entre empaquetados

**Garantía formal**: dos binarios Batamanta con UUIDs distintos **no pueden
compartir ningún recurso persistente**:

1. **Path del socket**: `/tmp/batamanta-<UUID_A>/keeper.sock` vs
   `/tmp/batamanta-<UUID_B>/keeper.sock` — paths disjuntos por construcción.
2. **Lock file**: `/tmp/batamanta-<UUID_A>/lock/` vs `/tmp/batamanta-<UUID_B>/lock/`
   — `mkdir` atómico por path; imposible que A piense que B tiene el lock.
3. **PID file**: análogo. Un wrapper de A solo hace `kill(pidA, 0)` sobre PIDs
   leídos del PID file de A; nunca de B.
4. **BEAM cookie**: el keeper genera un cookie aleatorio por instancia en
   `started_at` startup y lo escribe a un `cookie` file en su dir. (No
   implementa `epmd` ni `--sname`; la comunicación es por Unix socket, no por
   distribución Erlang. Esto es por diseño — ver §"Alternativas consideradas".)
5. **Code path**: `code:add_pathsa([...])` se hace con paths dentro de
   `/tmp/batamanta-<UUID>/release/lib/`. A no ve las apps de B y viceversa.
6. **Process registry**: cada BEAM tiene su propio `registered` namespace. Las
   apps del usuario se registran con nombres como `<App>.Supervisor` que
   viven en su BEAM. Si dos binarios del mismo `:my_app` arrancan, ambos
   registran `MyApp.Supervisor` en sus respectivas VMs — sin colisión.
7. **Ports/Sockets abiertos**: los abre la app del usuario dentro de su BEAM
   usando su propio file descriptor table (compartido a nivel SO, pero
   gestionado independientemente). No hay abstracción Batamanta sobre esto.

**Casos límite analizados**:

| Caso | Comportamiento esperado | Razonamiento |
|------|-------------------------|--------------|
| A y B mismo `:my_app` 0.1.0, mismo OTP, mismo payload, **distinto UUID** | Dos VMs independientes, dos sockets, dos BEAMs. Cada uno carga sus propias apps. | El path runtime es distinto. No comparten nada. |
| A y B mismo UUID (improbable: 122 bits de entropía) | Uno gana el `mkdir`, el otro reintenta con su UUID, ambos viven. | El UUID es per-binario, no per-ejecución. La probabilidad de colisión es 2^-122. |
| A arranca keeper, B llega, ambos en mismo `/tmp` | Cada uno mira su propio socket. B crea su lock_dir → EEXIST si A ya tiene uno → A es el starter, B es joiner. Sin colisión porque cada uno vive en su UUID-dir. | El lock es per-UUID. |
| A hace `kill(B_pid, 0)` por error | Imposible: A solo lee su propio `keeper.pid`. | El wrapper usa `pid_file = base_dir/keeper.pid` con `base_dir = /tmp/batamanta-<UUID_A>/`. |
| A y B comparten código OTP en disco (mismo `~/.cache/batamanta/erts-X.Y/`) | Sí, comparten el **cache de ERTS** (read-only, gestionado por `Batamanta.ERTS.Fetcher`). Es la **única compartición**, y es benigna: idéntica para todos los binarios Batamanta en la misma máquina. | El cache es inmutable, copy-on-write en el sentido de que cada extracción copia. No hay race. |

### Mecanismo de arranque: starter vs joiner

Algoritmo del cliente (`priv/rust_template/src/main.rs`):

```
fn try_connect_or_start(uuid: &str, ttl_ms: u64) -> UnixStream {
    let base_dir = format!("/tmp/batamanta-{}", uuid);
    let sock_path = format!("{}/keeper.sock", base_dir);
    let pid_file  = format!("{}/keeper.pid", base_dir);
    let lock_dir  = format!("{}/lock", base_dir);

    // Fast path: ¿hay keeper vivo?
    if let Ok(pid_str) = std::fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<i32>() {
            if unsafe { libc::kill(pid, 0) } == 0 {  // proceso vivo
                if let Ok(stream) = UnixStream::connect(&sock_path) {
                    return stream;  // joiner path
                }
            }
        }
    }

    // Slow path: no hay keeper, intentar arrancar
    // mkdir atómico sobre lock_dir. Solo uno de N concurrentes gana.
    match std::fs::create_dir(&lock_dir) {
        Ok(()) => {
            // Somos el starter
            let sock = start_keeper_and_connect(&base_dir, &sock_path, &pid_file, ttl_ms);
            // Marcar lock como completado (best effort: si falla, el siguiente
            // cliente verá sock y no el lock, no rompe nada).
            let _ = std::fs::remove_dir(&lock_dir);
            sock
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Otro cliente está arrancando. Esperar al socket con backoff.
            wait_for_socket(&sock_path, Duration::from_secs(30))
                .expect("keeper did not become ready in 30s")
        }
        Err(e) => panic!("lock_dir mkdir failed: {}", e),
    }
}
```

Algoritmo del starter (`start_keeper_and_connect`):

```
1. fork() — el padre será el wrapper, el hijo será el keeper.
2. En el hijo:
   a. setsid() — nueva sesión, para que el keeper sobreviva al wrapper.
   b. open socket_path via gen_tcp:listen({local, sock_path}, [...]) [en el
      lado Erlang] — pero antes, en Rust, hacemos:
      - mkdir(base_dir, 0o700) si no existe.
      - Crear el Unix socket listener directamente con bind(2) — pero NO:
        queremos que el keeper Erlang lo cree para tener el control del
        lifecycle. En su lugar, escribimos un placeholder sock y dejamos
        que el Erlang haga bind+listen. Si el socket ya existe (carrera
        rarísima), el Erlang falla y el siguiente cliente reintenta.
   c. execve("erlexec", ["-boot", "start_clean", "-mode", "embedded",
                          "-nohalt", "-noinput", "-s", "batamanta_keeper",
                          ...])
   d. El Erlang keeper:
      - application:load(batamanta_keeper)
      - application:start(batamanta_keeper)
      - keeper:bind_unix_socket(sock_path)
      - keeper:write_pid_file(pid_file)
      - keeper:start_inactivity_timer(ttl_ms)
      - keeper:listen_loop()
   e. Si el Erlang falla en < 1s, el wrapper padre detecta (poll PID), hace
      cleanup, y reporta error.
3. En el padre:
   a. Esperar a que el socket exista (poll con backoff, 5s total).
   b. Si existe: UnixStream::connect.
   c. Si no existe en 5s: keeper crashó en arranque → exit 1 con stderr
      explicativo.
4. Quien sea el cliente (joiner o starter) continúa con el protocolo.
```

**El keeper es el proceso background**. El wrapper cliente (en starter mode)
solo espera a que el socket esté listo y luego se conecta. **El wrapper NO espera
a que la primera request termine para salir** — eso es lo que permite baja
latencia: el wrapper hace su trabajo (connect + send + recv), exit 0; el keeper
sigue corriendo en background hasta el TTL.

**Reap del keeper**: el keeper NO tiene un proceso padre que lo reapa (el
wrapper ya hizo exit). El BEAM ignora `SIGCHLD` por default; cuando un child
process muere, queda como zombie hasta que el BEAM llama `wait`. Como el keeper
no spawnea procesos, esto es benigno. Si en el futuro hace falta, el keeper
instala un handler de `SIGCHLD` que llama `wait` no-bloqueante. (No en scope
de este RFC.)

### Manejo de señales

**Mecanismo refinado (decisión OQ-3)**:

1. El wrapper hace `fork()` sin `setsid()` ni `setpgid()`. El child keeper
   hereda el process group del wrapper.
2. El wrapper NO es session leader (su padre es la shell del usuario), así
   que cuando el wrapper.exit(0) por flujo normal, **el keeper NO recibe
   SIGHUP** — sobrevive al TTL.
3. El wrapper SÍ está en el foreground process group de la shell junto con
   su child. Ctrl+C de la shell → SIGINT al pgroup → ambos lo reciben.
4. El wrapper instala handlers que hacen `killpg(getpgrp(), sig)` para
   reenviar al keeper (que está en el mismo pgroup). 1 syscall por handler.

**El wrapper cliente instala handlers y propaga**:

| Señal | Wrapper cliente | Keeper (vía socket) | Notas |
|-------|-----------------|---------------------|-------|
| `SIGINT` (Ctrl+C) | `killpg(getpgrp(), SIGINT)` (wrapper + keeper lo reciben por pgroup) | Traslado a `kill(INT, user_app_pid)` para llegar al process group de la app del usuario | Wrapper y keeper mueren en este caso por la propagación del pgroup. El keeper queda limpio si la request estaba en curso. |
| `SIGTERM` | `killpg(getpgrp(), SIGTERM)` | `kill(TERM, user_app_pid)` | Idem. |
| `SIGHUP` | `killpg(getpgrp(), SIGHUP)` | `kill(HUP, user_app_pid)` | En la práctica, el wrapper nunca recibe SIGHUP de la shell (la shell no lo manda), pero lo manejamos por completitud. |
| `SIGWINCH` | Envía `SIGNAL WINCH\n` por socket | `io:rows()` del group_leader, propaga al TTY del usuario | Solo si stdout es TTY. |
| `SIGPIPE` | Ignorar | Ignorar (default Erlang) | Cliente: si el socket se rompe, recv retorna 0 → exit 0 (no error). |
| `SIGUSR1`/`SIGUSR2` | No hacer nada (reservados para debug del keeper) | No interceptar | |

**Por qué wrapper.exit(0) no mata al keeper**:

- El wrapper es hijo de la shell → no es session leader.
- Su child (el keeper) tiene como session leader la shell original, no al wrapper.
- Cuando el wrapper.exit(0), el kernel NO manda SIGHUP al child (porque el
  padre que murió no era session leader).
- El child queda como process huérfano, reapeado por `init` (PID 1).
- Sigue ejecutándose hasta que el inactivity timer lo pare.

**Caso edge: Ctrl+C en startup**. Si Ctrl+C llega antes de que el wrapper haya
hecho `fork()`, no hay keeper al que enviar nada y el wrapper sale con 130.
Si llega **después** del fork pero **antes** de que el erlexec haya hecho
`execve()`, la señal llega al child erlexec (C binary pre-exec), que muere
con `SIGINT` y el wrapper detecta el fallo por `waitpid` y reporta error
al usuario. Sin keeper huérfano en ninguno de los dos casos.

**Detección de keep-alive cancelado por usuario**: si el usuario quiere que
el keeper MUERA tras una SIGINT (no solo la request), el wrapper, además
de propagar vía pgroup, envía `SHUTDOWN\n` por socket → keeper para apps +
`init:stop()`. Esto se decide por un flag runtime
`BATAMANTA_BEAM_ALIVE_SHUTDOWN_ON_SIGINT` (default `false`).

### Manejo de stdout/stderr/exit code

**El keeper corre la app del usuario en un proceso temporal**:

```
batamanta_keeper_runner:run_request(Args, Env, Stdin) ->
    GroupLeader = create_tty_group_leader_or_pipe(),  % ver abajo
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        try
            Result = user_app:run(Args, Env, Stdin, GroupLeader),
            Parent ! {Ref, {ok, Result}}
        catch
            Class:Reason:Stack ->
                Parent ! {Ref, {error, {Class, Reason, Stack}}}
        end
    end),
    receive
        {Ref, Reply} -> Reply
    after TTL ->
        exit(Pid, kill),
        {error, timeout}
    end.
```

**Group leader (TLAU: this is the tricky part)**:

- Si el stdout del cliente es TTY (`isatty(1) == true`): el wrapper hace
  `ttyname(1)`, lee la ruta del TTY, la pasa al keeper por env var
  `BATAMANTA_USER_TTY=/dev/pts/3`. El keeper abre ese TTY y lo usa como
  group leader. Output del usuario va al mismo TTY que el wrapper, sin
  intermediarios.
- Si NO es TTY (pipe, redirect a file): el keeper crea pipes internos,
  forwardea byte-a-byte al cliente por el socket, y el cliente los escribe a
  su stdout. Esto es lo que permite `batamanta-cli | grep foo` o
  `batamanta-cli > out.log`.

**Trade-off documentado**: en el caso TTY, el output aparece mezclado con
potential output del wrapper (e.g. errores de protocolo). En la práctica, el
wrapper no escribe a stdout — solo a stderr. El output del usuario va al TTY
limpio. (Si hay race visual, ver §"Limitaciones conocidas".)

**Exit code**: el keeper captura el exit code del main de la app del usuario
(módulo CLI, `System.halt/1`, o return value de un `task`). Se propaga al
cliente que lo usa como exit code del wrapper. Conservación de semántica Unix.

**Stderr**: se trata idéntico a stdout (mismo group leader). Si la app del
usuario distingue stdout/stderr (e.g. logger config), se respeta porque el
group leader del usuario es el que escribía antes.

### Concurrencia

**Múltiples clientes simultáneos contra el mismo keeper**: es el caso normal.
El keeper mantiene **una cola FIFO de requests** con concurrencia de 1
(una request activa a la vez, las demás esperan en una `gen_server` queue).
Razonamiento:

- Si la app del usuario tiene state global (un singleton, una conexión DB),
  ejecutarla concurrentemente desde múltiples "instancias" del CLI es
  comportamiento **indefinido** (race conditions en la app del usuario). Mejor
  serializar.
- El coste de serializar es bajo: el tiempo de CPU ya está gastado; lo único
  que se gana con concurrencia es I/O solapado, que el user app no suele
  hacer entre invocaciones CLI.

**Robustez reforzada (decisión OQ-2)**:

1. **Timeout por request**: cada request tiene un deadline
   (`BATAMANTA_REQUEST_TIMEOUT_MS`, default 60 s). Si expira, el runner
   mata el proceso de la app del usuario con `exit(Pid, kill)` y devuelve
   `exit_code = 124` (estilo `timeout(1)`). Un loop infinito en la app
   del usuario no bloquea al keeper indefinidamente.
2. **Aislamiento del crash**: la app del usuario corre dentro de un
   `spawn_monitor` en el runner. Si crashea con un exit reason no-normal
   (e.g. NIF segfault que tumba el BEAM), el supervisor del keeper
   detecta, reinicia el server gen_server, y queda operativo para la
   siguiente request. Si el BEAM entero muere, lo detecta el wrapper
   cliente en la próxima invocación (PID file check) y levanta uno nuevo.

**Comportamiento**:

```
Cliente A conecta → keeper acepta, marca "running", ejecuta request.
Cliente B conecta → keeper acepta, marca "queued", espera.
Cliente C conecta → keeper acepta, marca "queued", espera.
A termina → keeper notifica a B → B ejecuta → B termina → C ejecuta.
```

**Si un cliente A se desconecta a mitad** (Ctrl+C, OOM, network issue):
el keeper detecta `tcp_closed` después de un timeout de 30s sin bytes →
cancela la request del usuario con `exit(Pid, kill)`, libera el slot,
atender al siguiente. (Decisión: 30s de grace period para distinguir
"cliente desconectado" vs "cliente conectado que está pensando".)

**Si el keeper muere a mitad** de una request: el cliente recibe `EPIPE` o
`recv=0` en su socket. El cliente:
1. Imprime a stderr: `keeper died during request, retrying as new instance`.
2. Limpia `/tmp/batamanta-<UUID>/keeper.pid` y `keeper.sock` (stale).
3. Repite el algoritmo "slow path" → crea un keeper nuevo → reintenta la
   request una vez. Si falla de nuevo: error fatal.

Esto da **transparencia ante crashes del keeper**: el usuario ve la request
tarda más, pero la app sigue funcionando.

### Recuperación ante fallos

| Fallo | Detección | Recuperación |
|-------|-----------|--------------|
| Keeper killed (SIGKILL, OOM) | `kill(pid, 0) == -1` en siguiente cliente | Próximo cliente hace slow path → crea keeper nuevo. Cleanup de `sock` y `pid` antes. |
| Socket roto pero PID vivo | Cliente connect falla con `ECONNREFUSED` | Mismo caso que keeper killed. |
| `lock_dir` stale (cliente murió entre `mkdir` y socket-up) | Otro cliente: `mkdir(lock_dir) → EEXIST` + poll sock hasta 30s | Si en 30s no hay socket, el cliente **asume que el starter murió** y procede como si fuera el starter (slow path, mkdir ok). Ver §"Open Questions" OQ-1. |
| Disco lleno durante extracción | `tar::Archive::unpack` retorna error | Wrapper exit 1, no se crea nada. Cliente siguiente reintenta (es idempotente). |
| ERTS corrupto en payload | erlexec falla al arrancar | Wrapper detecta (poll PID < 1s, exit != 0), cleanup, exit 1 con mensaje claro. |
| Aplicación del usuario crashea | El `spawn_monitor` del runner recibe `{'DOWN', _, _, _, Reason}` | Keeper responde con `exit_code = 1` (mapeo configurable) y stderr con el crash. Cliente propaga exit code. |
| TTY del usuario desaparece (TTY cerrada) | `isatty(1) == false` en siguiente invocación | Keeper detecta y re-configura group leader a pipes. |
| Cliente OOM/segfault durante request | `tcp_closed` en keeper | Keeper cancela la request con `kill`, libera slot. |

### Limpieza de recursos

| Recurso | Quién limpia | Cuándo |
|---------|--------------|--------|
| `/tmp/batamanta-<UUID>/` (directorio completo) | Wrapper cliente cuando sale (solo si es starter Y el keeper no quedó vivo) | Al final de `main`, solo si `keep_alive=false` en runtime. |
| `release/` (payload extraído) | Wrapper cliente en el mismo caso | Igual. **Si hay keeper vivo, NO se borra** — siguiente wrapper reusa. |
| `keeper.sock` | Keeper al hacer `init:stop()` (su último acto) | Cuando el TTL expira o shutdown explícito. |
| `keeper.pid` | Keeper igual | Igual. |
| `lock/` | El starter que tuvo éxito | Inmediatamente tras bind del socket. |
| `cookie` (si se implementa) | Keeper al shutdown | Igual que `keeper.sock`. |
| `started_at` | Keeper al shutdown | Igual. |
| **El payload NO se borra entre invocaciones** si hay keeper vivo. Esto es **deseable**: hot re-execute usa el mismo `release/` ya extraído. | — | — |

**Limpieza en arranque de nueva máquina / `batamanta.clean`**: el script
`Mix.Tasks.Batamanta.Clean` (existente) ya borra `batamanta_*` en tmp. **Cambio
necesario**: actualizar el patrón a `batamanta-*` (con guión) y a `batamanta_*`
(legacy) durante un período de deprecation. No es bloqueante.

### Compatibilidad

**Casos a garantizar**:

1. **Binario compilado sin `beam_alive:`** (legacy): el wrapper ni siquiera
   mira el env var. Path identical a actual. Test smoke cubre esto (ya existe
   en `smoke_tests/smoke_tests.sh`).
2. **Binario compilado con `beam_alive: [enabled: false]`**: idem. La
   opción existe en config pero no se bakes nada. Útil para opt-in gradual.
3. **Binario compilado con `enabled: true`, runtime sin env var**: el
   wrapper ve `enabled: true`, lee env var, ve `unset/""/"0"`, fallback a
   path legacy. Output idéntico al actual, cero latencia añadida (un check
   de string).
4. **Binario compilado con `enabled: true`, runtime con env var=30000**:
   alive mode activo, comportamiento nuevo.
5. **Mix project upgrade**: el consumidor que ya tiene binarios deployed
   puede actualizar la lib batamanta, recompilar, y obtiene binarios con
   `enabled: true` baked. Hasta que no setee el env var, comportamiento
   idéntico.

**Versioning**: el binario no cambia de formato. La feature es opt-in via
config + env var. No requiere cambio en `Cargo.toml` consumers ni en
`mix.exs` de proyectos que no la usen. **Semver: minor bump** (1.6.x →
1.7.0).

**Riesgo de "comportamiento fantasma"**: si alguien setea el env var en su
shell por error, todos los binarios Batamanta con `enabled: true` empiezan a
mantener BEAM viva. Esto es **deseable** (es exactamente la feature), pero
puede sorprender. Documentación: una sección en README, una nota en el
banner de `mix batamanta` si el build tiene `enabled: true`.

### Seguridad

**Aislamiento por UID**: el `/tmp` es por-usuario en sistemas razonables
(`/tmp` con sticky bit, pero cada usuario tiene sus directorios). El
`/tmp/batamanta-<UUID>/` se crea con `mkdir(..., 0o700)`. **El wrapper
abandona privilegios antes de fork** si se ejecuta setuid (recomendación
general; no implementamos setuid pero lo dejamos preparado). Para binarios
no-setuid (caso normal): cada usuario ve solo sus propios dirs. **No hay
riesgo cross-user** más allá del que ya tiene cualquier programa que escribe
a `/tmp`.

**Symlink attack**: un atacante que pueda escribir a `/tmp` con el mismo
UID **antes** de que el wrapper arranque podría hacer `ln -s /etc/passwd
/tmp/batamanta-<UUID>-attacker`. Mitigación: el wrapper usa `mkdir` atómico
sobre el directorio **y verifica que el path no existe como symlink** antes
de operar (`O_NOFOLLOW` en `open`, o `lstat` previo). Si el path es symlink
o ya existe como no-dir, **abortar con error claro** (no seguir adelante;
preferible un crash honesto a un exploit).

**Socket permissions**: el `gen_tcp:listen` en Erlang recibe
`[{ifaddr, {{local, sock_path}}, {active, false}, {reuseaddr, false}, {mode,
0o700}}]`. El Erlang chmod el socket file a `0o600` post-bind. **Solo el
mismo UID puede conectar**.

**Cookie del BEAM**: si en el futuro se habilita distribución Erlang
(`--sname`), el cookie es random per-instance, escrito a `cookie` file
con `0o600`, y nunca se transmite por el socket. (En este RFC, no se
implementa distribución — ver §"Alternativas consideradas".)

**Validación de input en protocolo**: el keeper valida que `arg_count`,
`env_count`, `ttl_reset_ms` sean enteros no-negativos dentro de rangos
razonables (e.g. `ttl_reset_ms <= 86_400_000` = 24h). Bytes > 64 KB
rechazados. UTF-8 enforcement en argv. **Denegación de servicio**: si un
cliente envía millones de requests en un segundo, el keeper se protege con
rate limiting simple (`enqueue_max = 100`, drops con error response).

**Command injection en `os:cmd`**: el keeper NO usa `os:cmd` para
propagar signals; usa `os:cmd("kill -INT " ++ Pid)` con `Pid` validado
como entero. **No** concatena strings del usuario. Ver `runner.erl:signal/2`.

**Path traversal**: el keeper NUNCA escribe fuera de `/tmp/batamanta-<UUID>/`
basado en input del cliente. El path del socket es baked, no viene del
cliente.

**Falsificación de UUID**: imposible sin acceso de escritura a `/tmp`. El
UUID se genera en build time, en una máquina de build, y se confía en él
(igual que se confía en el `app_name`).

### Limitaciones conocidas (documentar, no resolver en este RFC)

1. **argv no-UTF-8**: rechazado. Workaround futuro: usar `argv` como binario
   raw, separado del protocolo textual.
2. **env vars con `\n`**: rechazado. Workaround: variables largas via file
   descriptor pasado por SCM_RIGHTS (Unix). No en scope.
3. **Stdout del user app aparece en TTY mezclado con stderr del wrapper**:
   en TUI interactivos, puede haber orden visual raro si el wrapper tiene que
   imprimir errores mientras el user app imprime a stdout. Workaround: el
   wrapper escribe solo a stderr; en modo interactivo largo, considerar
   buffering de errores hasta el final.
4. **Sin hot reload de la app del usuario**: si el usuario recompila la app,
   el keeper debe reiniciarse (porque los `.beam` están en el `code:path` de
   una VM ya arrancada). Workaround: comando `RELOAD\n` en el protocolo →
   keeper para apps, recarga paths, rearranca. **No en scope de este RFC**.
5. **Máquina se suspende (laptop sleep) y se reanuda**: el TTL basado en
   `erlang:monotonic_time()` sobrevive (es monotónico, no wallclock), pero
   sockets abiertos pre-suspensión pueden quedar en estado raro. Workaround:
   al reanudar, el primer cliente detecta socket stale y reinicia.
6. **Watcher NIF cargado a la app del usuario**: la primera carga lo
   inicializa; las requests subsecuentes lo reusan. No hay problema aquí
   salvo que la NIF tenga state global no thread-safe — eso es problema de
   la app, no del keeper.

## Alternativas consideradas

### 1. Comunicación: distribución Erlang (`epmd` + `--sname` + `rpc:call`)

- **Pros**: integrado en Erlang/OTP, semántica rica (cualquier módulo exporta
  funciones remotamente), autenticación via cookie.
- **Contras**:
  - `epmd` no es trivial de embeber: necesita arrancar un daemon y mantener
    mapping puerto↔nombre. Más peso que un Unix socket.
  - Cookie file tiene que ser leído por el wrapper Rust, que tendría que
    parsearlo y enviarlo. Frágil.
  - `--sname` añade overhead: 1 daemon por binario Batamanta en la misma
    máquina colisionaría por nombre. Solución: nombre random — pero entonces
    el cliente tiene que descubrirlo, lo que requiere un canal paralelo.
  - `rpc:call` parsea términos Erlang en el wrapper Rust. Inverted control:
    el wrapper tendría que tener un parser de `external term format` o un
    bridge. Demasiado peso.
- **Veredicto**: **descartado**. El Unix socket con protocolo ad-hoc es más
  simple, más pequeño, más rápido, y solo necesita primitive de SO que están
  en el stdlib de Rust.

### 2. Comunicación: HTTP sobre Unix socket

- **Pros**: tooling estándar (`curl --unix-socket`), debug fácil, libs en
  cualquier lenguaje.
- **Contras**: parsing HTTP en el keeper (overhead), payloads grandes
  (headers), semántica request/response contaminada por Connection: close
  vs keep-alive que no necesitamos.
- **Veredicto**: **descartado**. Demasiado overhead para algo tan simple.

### 3. Identificación: hash estable del payload

- **Pros**: reproducible — el mismo binario tiene el mismo hash siempre.
- **Contras**: dos binarios del mismo proyecto, mismo version, mismo commit
  → colisión garantizada. Pierde el caso multi-cuenta.
- **Veredicto**: **descartado**. UUID es la elección correcta.

### 4. Identificación: hash del payload + timestamp de build

- **Pros**: cambia con cada build, evita colisión trivial.
- **Contras**: dos binarios en CI con el mismo commit y misma config →
  mismo hash si el build es determinista (que debería ser). Y fugas de
  información sobre el build.
- **Veredicto**: **descartado**, igual que hash estable.

### 5. TTL configurable en mix config (Opción A original)

- **Veredicto**: **descartado**, ver tabla §"Configuración". Falta de
  flexibilidad para testing y dev loops.

### 6. Sin env var, siempre alive

- **Pros**: ultra simple, sin config runtime.
- **Contras**: si la app del usuario es interactiva (e.g. un REPL), no
  podemos tener un "modo single-shot" sin recompilar.
- **Veredicto**: **descartado**. La opción C es más flexible sin coste.

### 7. Wrapper hace fork+exec directo del `bin/<app>` del release, sin keeper

- **Pros**: aún más simple. Cero código Erlang.
- **Contras**: cada invocación paga arranque. Esto es exactamente lo que
  queremos evitar.
- **Veredicto**: **descartado**. Es el "no hacer nada".

### 8. Beamparticle / persistent_term / global state para "no arrancar"

- **Pros**: trampa. No es lo que pide el usuario.
- **Contras**: las apps del usuario tienen su `start/2` que hace setup
  (config, supervisor tree, DB pool). No podemos saltárnoslo sin que el
  usuario reescriba su app.
- **Veredicto**: **descartado**, ni siquiera es una alternativa real.

### 9. Compilar el keeper con `erlc` del host (no `elixirc`)

- **Pros**: una dep menos.
- **Contras**: el host podría tener un `erlc` con versión distinta al ERTS
  embebido → `.beam` no compatibles. `elixirc` del ERTS del release es la
  fuente de verdad.
- **Veredicto**: **descartado**, usar siempre el `elixirc` del ERTS target.

### 10. Lock con `flock(2)` en lugar de `mkdir(2)`

- **Pros**: API más estándar para lock files.
- **Contras**: `flock` sobre un file pre-existente requiere que el file
  exista antes, lo que crea un TOCTOU entre `open` y `flock`. `mkdir(2)` es
  inherentemente atómico para "existe o no existe".
- **Veredicto**: **descartado**, `mkdir` es la primitive correcta.

## Plan de implementación por fases

Cada fase tiene **criterios de éxito verificables**. Las fases se
implementan en orden. Cada fase termina con un commit + smoke test passing.

### Fase 0: Baseline y limpieza de drift (≈0.5 día)

**Objetivo**: dejar el repo en estado conocido.

1. Limpiar `priv/rust_template/Cargo.lock`: quitar `uuid`, `ctrlc`, `libc`,
   `md5`, `sha2`, `tempfile` que ya no están en `Cargo.toml`.
2. Documentar en `AGENTS.md` la nueva feature como T-008.
3. Crear `doc/rfcs/0008-beam-alive-mode.md` (este RFC) y enlazarlo desde
   README.

**Criterio de éxito**: `cargo build` no cambia de tamaño; `mix test` pasa
igual que antes; `git grep uuid` en `priv/rust_template/src` retorna 0.

### Fase 1: UUID bakeado sin alive mode (≈1 día)

**Objetivo**: introducir la identificación única sin cambiar comportamiento.

1. Añadir `uuid = { version = "1", features = ["v4"] }` a
   `priv/rust_template/Cargo.toml`.
2. Modificar `priv/rust_template/build.rs` para generar
   `GENERATED_INSTANCE_ID`.
3. Modificar `priv/rust_template/src/main.rs` para usar
   `/tmp/batamanta-<UUID>/` en lugar de `/tmp/batamanta_<app>_<prefix8>/`.
4. Mantener el path legacy `/tmp/batamanta_<app>_<prefix8>/` en una
   constante `LEGACY_PATH_SUPPORT = true` por un minor version (compat con
   binarios viejos que se ejecuten en la misma máquina). Quitar en 1.8.0.

**Criterio de éxito**:
- `mix test` pasa.
- `mix batamanta` produce binario; ejecutarlo 2 veces: ambas ven el mismo
  `/tmp/batamanta-<UUID>/` (UUID estable).
- El binario NO usa el env var `BATAMANTA_BEAM_ALIVE` aún.

### Fase 2: Estructura Elixir del keeper config + compilación de `.beam` (≈1.5 días)

**Objetivo**: el binario lleva el código del keeper, pero no se invoca.

1. Crear `lib/batamanta/keeper_config.ex` con normalización + validate!.
2. Crear `lib/batamanta/keeper.ex` con `compile/3` (staging rel_path,
   erts_path, opts) que invoca `elixirc` del ERTS para producir
   `batamanta_keeper_*.beam` en `rel_path/lib/batamanta_keeper-0.1.0/ebin/`.
3. Crear los 5 módulos Erlang en `priv/keeper/src/` con stubs que
   compilen pero hagan `init:stop()` al arrancar.
4. Modificar `lib/batamanta/packager.ex` y `lib/batamanta/escript_packager.ex`
   para invocar `Batamanta.Keeper.compile/3` cuando
   `bata_config[:beam_alive][:enabled] == true`.
5. `lib/batamanta/validator.ex`: añadir validación.

**Criterio de éxito**:
- `mix test` pasa.
- `mix batamanta` con `beam_alive: [enabled: true]` produce un payload que
  contiene `release/lib/batamanta_keeper-0.1.0/ebin/batamanta_keeper_*.beam`.
- `ls -la /tmp/batamanta-<UUID>/release/lib/batamanta_keeper-0.1.0/ebin/`
  muestra los `.beam` después de ejecutar el binario.
- Smoke test existente pasa (sin alive mode, comportamiento legacy).

### Fase 3: Wrapper cliente con IPC dispatch (≈2 días)

**Objetivo**: el wrapper detecta el flag, lee el env var, hace connect
a un socket que no existe aún (debe fallar y fallback a legacy).

1. Modificar `priv/rust_template/build.rs` para serializar el flag
   `BEAM_ALIVE_ENABLED` y la config (var name, default).
2. Crear `priv/rust_template/src/ipc.rs` con `connect_unix_socket/2`,
   `send_request/2`, `read_response/1`.
3. Modificar `priv/rust_template/src/main.rs`:
   - Lee `GENERATED_BEAM_ALIVE_ENABLED`.
   - Si `false` → path legacy (sin cambios).
   - Si `true` → lee env var `BATAMANTA_BEAM_ALIVE_VAR` (con
     `GENERATED_BEAM_ALIVE_DEFAULT_MS` como fallback).
   - Si no hay valor: path legacy + warning a stderr.
   - Si hay valor: connect a `/tmp/batamanta-<UUID>/keeper.sock` →
     `Err(...)` (no existe) → path legacy + warning "alive mode requested
     but no keeper running; falling back".
4. Añadir tests Rust: `cargo test` en `priv/rust_template/`.

**Criterio de éxito**:
- `cargo test` en Rust pasa.
- Smoke test con `BATAMANTA_BEAM_ALIVE=30000 ./bin` imprime warning y
  termina con el path legacy (mismo exit code, mismo output, misma
  duración que sin env var).

### Fase 4: Keeper mínimo (≈2 días)

**Objetivo**: el keeper arranca, bind socket, escribe PID file, espera,
acepta una connection, responde, sale.

1. Implementar `batamanta_keeper_app.erl` (application callback).
2. Implementar `batamanta_keeper_sup.erl`.
3. Implementar `batamanta_keeper_server.erl` con:
   - `init/1`: bind `gen_tcp:listen` en `sock_path` (env var), set inactivity
     timer, return `{ok, #state{}}`.
   - `handle_call({request, Args, Env, Stdin}, From, State)`: spawn
     monitor, esperar reply con timeout, responder.
   - `handle_info(timeout, State)`: `init:stop()`.
   - `terminate/2`: cleanup (unlink socket, remove pid file).
4. Implementar `batamanta_keeper_protocol.erl` con encode/decode del
   protocolo (stubs: solo HELLO/RSP error=not_implemented).
5. Implementar `batamanta_keeper_runner.erl` (stub: responde
   "not implemented" hasta Fase 5).
6. Modificar `priv/rust_template/src/main.rs` para que el starter fork + exec
   `erlexec` con los args correctos.

**Criterio de éxito**:
- `mix batamanta` con `enabled: true` produce binario.
- `BATAMANTA_BEAM_ALIVE=30000 ./bin 1 2 3` →
  - Primera invocación: spawn keeper (~150 ms extra), connect, send,
    receive "not implemented", exit 0.
  - Segunda invocación (dentro de 30s): connect a keeper existente, send,
    receive "not implemented", exit 0 (debería tardar < 5 ms extra).
- `ps aux | grep beam` muestra el BEAM corriendo entre invocaciones.
- Después de 30s sin actividad, BEAM desaparece.

### Fase 5: Keeper runner real (≈2 días)

**Objetivo**: el keeper ejecuta la app del usuario y propaga stdout/stderr/exit.

1. Implementar `batamanta_keeper_runner:run_request/4` que:
   - Detecta formato (release vs escript) vía env var `BATAMANTA_FORMAT`.
   - Si release: `application:load(<user_app>)`, luego
     `application:ensure_all_started(<user_app>)`.
   - Si escript: `escript:run(<path>, Args)` (más simple, escript no es
     OTP app supervisado).
   - Captura group leader (TTY detection).
   - Ejecuta con timeout (env var `BATAMANTA_REQUEST_TIMEOUT_MS`,
     default 60s).
   - Devuelve `{ExitCode, Stdout, Stderr}`.
2. Implementar protocol encode/decode completo (request + response).
3. `application:stop(<user_app>)` al final (sin matar BEAM).

**Criterio de éxito**:
- Test: app del usuario `MyApp.CLI.main(["hello", "world"])` se ejecuta
  y propaga stdout/exit code correctamente.
- Múltiples invocaciones dentro del TTL: cada una ve la app arrancada
  desde `application:start`, ejecutada, parada.
- App con `mix release --deploy` que abre conexión DB: la conexión
  persiste entre invocaciones → se mide mejora de latencia.

### Fase 6: Señales y robustez (≈1.5 días)

**Objetivo**: signals bien propagadas, recuperación ante keeper killed.

1. `priv/rust_template/src/signal.rs` con handlers + propagación.
2. `batamanta_keeper_server:handle_info({tcp_closed, ...}, ...)`: cancela
   request en curso.
3. Wrapper cliente: si recibe EOF del socket antes de RSP, retry una vez
   con cleanup.
4. Tests de stress: matar keeper con `kill -9` entre invocaciones,
   verificar que el siguiente wrapper levanta uno nuevo.

**Criterio de éxito**:
- Ctrl+C durante invocación: la app del usuario recibe SIGINT y termina
  con código 130 (128+2).
- `kill -9 <keeper_pid>` durante request: cliente detecta, retry,
  siguiente invocación funciona.

### Fase 7: Concurrencia y queue (≈1 día)

**Objetivo**: múltiples clientes simultáneos serializados correctamente.

1. `batamanta_keeper_server`: cola FIFO de requests.
2. `gen_tcp:listen` con `backlog = 16`.
3. Cliente: timeout de espera en cola (env var
   `BATAMANTA_QUEUE_TIMEOUT_MS`, default 30s).

**Criterio de éxito**:
- 3 invocaciones simultáneas (e.g. `for i in 1 2 3; do ./bin $i & done`):
  todas completan, exit codes correctos, ningún mensaje mezclado en
  stdout.

### Fase 8: Documentación y polish (≈1 día)

**Objetivo**: docs, ejemplos, banner, warnings.

1. README sección "BEAM Alive Mode" con ejemplo de config y env var.
2. `mix batamanta` con `enabled: true`: print una línea en el banner
   "🟢 BEAM alive mode available (set BATAMANTA_BEAM_ALIVE=30000 to enable)".
3. Ejemplo en `smoke_tests/test_alive/` (NUEVO directorio): proyecto
   simple que usa la feature y test e2e.
4. CHANGELOG entry.

**Criterio de éxito**:
- `mix docs` incluye nueva sección.
- Smoke test del proyecto alive pasa en CI.
- Un usuario externo lee README y puede activar la feature sin
  asistencia.

**Total estimado**: ~10 días hábiles para una sola persona.

## Criterios de aceptación (checklist final)

### Funcionales

- [ ] Binario legacy (sin `beam_alive:`) → comportamiento idéntico al actual
      (smoke test pasa sin cambios).
- [ ] Binario con `enabled: true`, sin env var → comportamiento idéntico al
      actual.
- [ ] Binario con `enabled: true`, env var=30000, 1ª invocación → keeper
      arranca, request se ejecuta, exit code correcto.
- [ ] Binario con `enabled: true`, env var=30000, 2ª invocación dentro de
      TTL → reusa keeper, < 50 ms de overhead vs invocación legacy.
- [ ] TTL expira → keeper muere solo, cleanup de `sock`/`pid` files.
- [ ] Tres invocaciones concurrentes → todas completan, exit codes
      correctos, sin mensajes mezclados.
- [ ] `kill -9 <keeper_pid>` durante ejecución → siguiente invocación
      recupera, request se completa.
- [ ] Ctrl+C durante ejecución → app del usuario recibe SIGINT, exit code
      130.
- [ ] Dos binarios del mismo `:my_app` 0.1.0 en la misma máquina, mismo
      payload, **distinto UUID** → ambos corren independientes (cada uno su
      socket, su lock, su BEAM).

### No funcionales

- [ ] Tamaño del binario aumenta < 100 KB (compresión incluida).
- [ ] Latencia de wrapper sin alive mode aumenta < 0.5 ms (un check de
      bool + lectura de env var).
- [ ] Tamaño del código Rust wrapper: ≤ 220 líneas (target: 180).
- [ ] Tamaño del código Erlang keeper: ≤ 600 líneas.
- [ ] `cargo test` y `mix test` pasan.
- [ ] Smoke test en `smoke_tests/test_alive/` pasa.
- [ ] Sin warnings nuevos en compilación (credo strict, dialyzer).
- [ ] Backward compatible: binarios 1.6.x siguen funcionando en máquinas
      con 1.7.x instalado y viceversa.

### Seguridad

- [ ] `/tmp/batamanta-<UUID>/` tiene `0o700`.
- [ ] `keeper.sock` tiene `0o600`.
- [ ] `cookie` (si se usa) tiene `0o600` y nunca se transmite por el
      socket.
- [ ] Path del socket no es symlink (validación `lstat` o `O_NOFOLLOW`).
- [ ] `os:cmd` no concatena strings del usuario.
- [ ] Rate limiting en keeper (no documentado en este RFC, pero
      implementado en Fase 4).

### Tests específicos a implementar

**Unitarios Elixir** (`test/batamanta/`):

- `keeper_config_test.exs`:
  - normaliza config válida
  - rechaza `enabled: true` sin `var:`
  - rechaza `default_ms > 86_400_000`
  - defaults sensatos

- `keeper_compile_test.exs`:
  - mockea `elixirc` y verifica que se invoca con los args correctos
  - verifica que deposita `.beam` en el path correcto
  - mockea fallo de `elixirc` y verifica error handling

- `packager_alive_test.exs`:
  - con `enabled: true`, el payload contiene `batamanta_keeper-0.1.0/`
  - con `enabled: false`, el payload NO contiene `batamanta_keeper-0.1.0/`

**Unitarios Rust** (`priv/rust_template/src/`):

- `ipc.rs`:
  - mock socket: send/receive protocol line-by-line
  - protocolo encode/decode roundtrip
  - response demasiado larga → error
  - invalid encoding → error

- `lockfile.rs`:
  - mkdir EEXIST → joiner path
  - mkdir ok → starter path
  - stale lock + socket inexistente → cleanup + starter path

**Unitarios Erlang** (en `priv/keeper/test/`):

- `batamanta_keeper_protocol_test.erl`:
  - encode HELLO → "HELLO\n"
  - decode REQ completo
  - encode RSP con stdout binario
  - decode RSP error=*

- `batamanta_keeper_server_test.erl`:
  - init/1 con `sock_path` → bind exitoso
  - handle_call request → spawn monitor + reply
  - handle_info timeout → init:stop
  - handle_info {tcp_closed, _} → cancela request

- `batamanta_keeper_runner_test.erl`:
  - app de test arranca y devuelve exit 0
  - app de test con crash devuelve exit 1
  - timeout funciona

**Integración** (`test/integration/alive_mode_test.exs` — nuevo):

- build binario con `enabled: true`
- ejecutar 3 veces, verificar que la 2ª y 3ª son < 50 ms
- ejecutar 2 concurrentes, verificar exit codes correctos
- `kill -9` keeper, ejecutar de nuevo, verificar recovery
- ejecutar 2 binarios del mismo payload (distinto UUID en build), verificar
  aislamiento (sockets distintos, BEAMs distintos, no se interfieren)

**Smoke** (`smoke_tests/test_alive/` — nuevo):

- proyecto dummy `test_alive` con `beam_alive: [enabled: true]`
- `smoke_tests.sh` extendido: corre test_alive 3 veces con env var
- assertion: las 3 ejecuciones pasan, total wall-time < 800 ms (con TTL
  5000 ms; legacy wall-time > 1.5s)

## Trabajo futuro

Esto queda fuera del scope del RFC pero es relevante para iteraciones
siguientes:

1. **Watcher protocol** (`WATCH\n` en el keeper): el wrapper se suscribe a
   eventos de la app del usuario (logs, métricas) y los forwardea. Útil
   para debugging interactivo.

2. **Stateless mode** (alternativa a alive mode): el wrapper siempre
   arranca un BEAM nuevo pero cachea `.beam` files compilados en
   `/tmp/batamanta-<UUID>/beam_cache/`. La 2ª invocación es rápida sin
   estado persistente entre invocaciones. Trade-off: menos memory
   pressure, peor latencia que alive mode.

3. **Keep-alive por socket persistente**: en lugar de reconnect por
   request, el cliente abre socket una vez y envía N requests. Útil para
   wrappers que llaman al binario N veces seguidas (scripts de CI
   largos).

4. **Cross-process kill semantics**: si el wrapper recibe SIGKILL
   (improbable, pero posible), el keeper no recibe cleanup signal y queda
   corriendo. Heartbeat protocol para que el keeper detecte "mi último
   cliente desapareció" y se suicide.

5. **Distribution Erlang opcional**: si un usuario quiere tener varios
   binarios Batamanta comunicándose entre sí, exponer `--sname` + cookie
   file. No en scope porque la mayoría de CLIs no lo necesitan, pero
   factible añadir en 1.8.0.

6. **Windows**: usar named pipes en lugar de Unix sockets. Compatible con
   el protocolo línea-a-línea, solo cambia el transporte. Solo tiene
   sentido si se reactiva el soporte Windows (ver `AGENTS.md`: "Sin
   Windows" por ahora).

7. **Métricas**: el keeper expone `STATS\n` → `{uptime_ms, requests_served,
   avg_request_ms, last_invocations: [...]}`. Útil para diagnóstico
   desde la CLI del usuario: `batamanta-foo --alive-stats`.

8. **Soporte para `mix run --no-halt` style**: integrar el alive mode con
   un comando `iex` equivalente, donde la app del usuario recibe un
   REPL. Esto es básicamente `iex` corriendo dentro del keeper, con
   que cada `iex>` line es una request.

9. **Reducir LOC del wrapper**: si en futuras iteraciones el wrapper
   crece más allá de 250 líneas, considerar mover parte de la lógica a
   un `lib/batamanta_runtime/` (librería Rust compilada, no script).
   Trade-off: más complejidad de build, mejor modularidad.

> **Nota sobre hot reload**: queda **explícitamente fuera de scope** por
> diseño. Batamanta es la frontera final del proceso de desarrollo: el
> binario es el artefacto que se distribuye y se ejecuta en producción.
> Recompilar produce un binario con un UUID distinto; el viejo keeper
> sigue corriendo hasta su TTL mientras el nuevo arranca en otro dir. No
> hay mecanismo (ni lo habrá) para "actualizar" la app dentro de un keeper
> vivo. Si quieres hot reload, usa `mix run --no-halt` o `iex -S mix`
> durante el desarrollo — no Batamanta.

## Open Questions (necesitan decisión del usuario)

1. **OQ-1: Stale `lock_dir` recovery timeout.** Si un cliente muere
   entre `mkdir(lock_dir)` y la creación del socket, el `lock_dir` queda
   ahí. Otro cliente ve `EEXIST` + poll sock con timeout. **¿Cuánto?**
   - 30s (propuesto en este RFC): razonable para arranque de BEAM (~150
     ms típico, < 1s casos patológicos).
   - 5s: más rápido para el caso "starter murió", pero riesgo de race
     si el BEAM tarda más de 5s en arrancar (proyectos muy pesados con
     NIFs de carga lenta).
   - Necesito decisión explícita. Mi recomendación: **30s**, ajustable
     por env var `BATAMANTA_LOCK_TIMEOUT_MS`.

2. **OQ-2: Concurrencia en el keeper.** La propuesta actual es FIFO con
   concurrencia 1. **¿Confirmar?** Alternativa: N>1 workers paralelos
   (más complejo, races en la app del usuario). Mi recomendación:
   **FIFO/1** (más simple, comportamiento predecible).

3. **OQ-3: Ctrl+C durante el startup del keeper.** Si llega SIGINT al
   wrapper mientras el keeper está arrancando (en los primeros 150 ms),
   no hay PID al que enviar la señal. **¿Comportamiento esperado?**
   - A (propuesto): el wrapper sale con código 130; el keeper puede
     quedar corriendo (será reaped por el inactivity timer si nadie lo
     usa). Riesgo: keeper "huérfano" 30s.
   - B: el wrapper hace `kill(0, SIGINT)` (process group) — mata
     también al keeper. Más limpio, pero el wrapper tiene que hacer
     `setpgid(0, 0)` antes del fork.
   - Necesito decisión. Mi recomendación: **B** (más correcto, cuesta
     1 syscall extra).

4. **OQ-4: Path del socket con `XDG_RUNTIME_DIR`?** En sistemas con
   `XDG_RUNTIME_DIR` definido (la mayoría de Linux modernos), el path
   canónico sería `$XDG_RUNTIME_DIR/batamanta-<UUID>/` en lugar de
   `/tmp/batamanta-<UUID>/`. **Pros**: mejor cleanup en logout
   (systemd lo limpia), mejor aislamiento (no comparte `/tmp` con todo).
   **Contras**: el path es por-sesión, lo que significa que el keeper
   muere al logout (puede ser deseable o no).
   - Necesito decisión. Mi recomendación: **usar XDG_RUNTIME_DIR si
     existe, fallback a `/tmp`**. Si no existe (`/var/run` raro,
     containers), usar `/tmp`. Default conservador.

5. **OQ-5: Nombre del env var default.** La propuesta usa
   `BATAMANTA_BEAM_ALIVE` como default si el usuario no setea
   `beam_alive.var`. **¿Confirmar?**
   - Pros: nombre genérico, no colisiona con vars de usuario.
   - Contras: si dos proyectos querem usar el MISMO nombre, no pueden
     coexistir. Pero la opción C del RFC ya permite `var:` por proyecto.
   - Necesito confirmación. Mi recomendación: **`BATAMANTA_BEAM_ALIVE`**
     como default universal.

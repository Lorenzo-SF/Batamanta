# Batamanta — Agent Summary

## Goal

Ship `batamanta` 2.0.0-dev as the personal Elixir ecosystem's
packaging primitive: self-contained release binaries that bundle a
pinned ERTS from `Lorenzo-SF/Batamanta---ERTS-repository` with no
Erlang/Elixir install required on the target machine. After the 1.6.x
re-architecture (no-flatten ERTS + Rust dispenser + `.run` script),
the focus is on **alignment with the renamed upstream manifest** and
**cleaning up the legacy code paths that the rename exposed** (most
notably the JSON parser in `Fetcher` and the cache directory layout
that assumed a single `linux-glibc` key per `OTP-X.Y.Z` release).

## Constraints & Preferences

- batamanta must support the 6 currently-built OS/arch combinations
  (linux glibc × amd64/arm64, linux musl × amd64/arm64, darwin
  arm64, windows amd64) plus the 2 latent ones kept for future
  reactivation (darwin amd64, windows arm64 — code is there, no
  upstream releases). macOS x86_64 is **not** currently published by
  the upstream mirror; the `:macos_12_x86_64` target still resolves
  via system ERTS at runtime.
- `lib/batamanta/target.ex` is the single source of truth for the
  target matrix; the Fetcher and packagers delegate to it.
- Pin floor: Elixir 1.18 (`@elixir_vsn "~> 1.18"` in `mix.exs`).
  OTP floor is 27.0 for **upstream-pulled** ERTS (see
  `Lorenzo-SF/Batamanta---ERTS-repository`); the Fetcher itself is
  more permissive because locally-installed system ERTS can still be
  used as a fallback.
- No Windows ARM64 — upstream `erlang/otp` doesn't ship prebuilt
  arm64 Windows binaries, so there's no reliable source to mirror.
  Use `windows_x86_64` (runs on arm64 via the x86_64 emulation
  layer) until upstream changes this.
- Idempotent build state — `mix batamanta` can be re-run, the Fetcher
  resumes from `.build-state.json`, lock files prevent races.
- Tests must pass with `mix test`; the `:integration` tag gates
  anything that hits the public GitHub raw URL.

## Progress

### Done

- **1.6.x series (re-architecture)**: no-flatten ERTS, Rust dispenser
  reduced to ~100 lines, `.run` script generated at build time,
  `Mix.Tasks.Batamanta` passes `execution_mode` to the packagers.
- **2.0.0-dev metadata**: `lib/batamanta.ex` `@version` and
  `mix.exs` `@version` aligned to `2.0.0-dev`. `CHANGELOG.md` has
  the `[2.0.0-dev] - Unreleased` block.
- **Manifest regeneration**: `priv/erts_repository/MANIFEST.json`
  regenerated from `Lorenzo-SF/Batamanta---ERTS-repository` to use
  the new `linux-glibc-amd64` / `linux-musl-amd64` /
  `darwin-arm64` / `windows-amd64` keys (was the old
  `amd64-glibc` / `arm64-*` / `darwin-amd64` which no longer exist
  on the upstream mirror).
- **`manifest_compat_test.exs`**: added `latest_full_version/1` helper
  that picks the most recent OTP version in the manifest that has
  every target's `manifest_key` present — required because OTP
  28.4.2+ ships without musl upstream, so the absolute-latest version
  is no longer suitable for full-matrix coverage tests.
- **`Fetcher` mini-JSON-parser removed**: the regex-based
  `extract_key_values/1` + `parse_json_value/1` is gone; `Jason` is
  now an explicit dep and the 4 helpers collapse into
  `defp parse_json(json_string), do: Jason.decode!(json_string)`.
  That's ~30 lines of fragile code deleted, and we get correct
  behaviour for nested objects, escaped strings, arrays, numbers,
  booleans, and null.
- **`Fetcher.check_erts_cache/2` simplified**: the `legacy_dir`
  branch (which collides across OTP versions because it didn't
  include the version in the path) is removed. The cache is now
  keyed strictly as `erts-{version}-{platform_key}`.
- **`Target.resolve_auto/2` clause removed**: the
  `def resolve_auto(nil, config)` clause was redundant with the
  `is_atom(target_atom)` clause that came before it (Elixir 1.18
  emits a warning for the redundant match).
- **`rust_template.ex` and `validator.ex` moduledocs updated**:
  `rust_template.ex` no longer says "Windows coming soon" (it ships
  since 1.6.1); `validator.ex` moduledoc now correctly aligns the
  OTP/Elixir version policy with the upstream floor (27+) and the
  `mix.exs` pin (1.18+) while documenting that the validator
  constants remain more permissive for back-compat with local
  system ERTS.
- **`Target` moduledoc**: added a "Targets whose upstream release
  is not currently published" section for `:macos_12_x86_64`.

### Blocked

- (none)

## Key Decisions

- **Jason is an explicit dep** (was transitively pulled via credo +
  excoveralls; now listed in `mix.exs` so the Fetcher can use it
  directly). Pin: `~> 1.0`.
- **Cache layout is version-aware**: every cache lookup keys on
  `erts-{version}-{platform_key}`. The legacy `linux-glibc-amd64/`
  shape (no version) is gone — old caches will be re-extracted on
  first use and cost a one-time download.
- **`latest_full_version/1` over hard-coded 28.4.1**: hard-coding
  would need to be revisited every time upstream drops a target.
  The helper computes "latest version where every target key is
  present" at test time, so the floor is data-driven.
- **`defp parse_json/1` returns a Jason-shaped map directly**: the
  caller (`load_manifest/0`, `find_erts_url/3`) already expected
  `Map[String.t(), String.t() | Map[String.t(), String.t()]]`,
  which is exactly what `Jason.decode!/1` produces. No further
  normalisation.
- **Moduledocs over inline comments for cross-cutting policies**:
  the OTP/Elixir floor mismatch (upstream 27+ vs validator 25+)
  is documented in `validator.ex`'s moduledoc, not in a code
  comment, because the explanation needs to surface in `mix docs`
  too.

## Next Steps

1. **Audit Fase 2** (post-Plan B cleanup of the ERTS repo):
   - `packager.ex` compression refactor (magic bytes + multi-backend)
   - `test/smoke_test.exs` is still a placeholder moduledoc; replace
     with at least one local smoke test that doesn't need the CI
     Docker matrix.
   - `lib/batamanta/release/step.ex` (16 lines) — sanity check.
2. **CI for batamanta** (PR #17): green once the manifest/JSON
   refactor lands on `main`.
3. **Moduledoc sweep for the remaining `lib/batamanta/*.ex`
   files**: the policy/version annotations are aligned, but
   `fetcher.ex`'s moduledoc still has the "(coming soon)" tone in
   places; revisit when adding more download strategies.
4. **Update tests for the new manifest layout**: the
   `manifest_compat_test.exs` is the only test that hits the
   upstream URL; add a "smoke" test that runs against the local
   `priv/erts_repository/MANIFEST.json` so CI doesn't have to
   round-trip to GitHub to catch a renames.

## Critical Context

- The `mix.exs` `@elixir_vsn "~> 1.18"` is the source of truth.
  Anything that says "Elixir 1.15+ minimum" is the *runtime* floor
  (validator still permits older Elixir for system-ERTS fallback);
  the build *requires* 1.18+ because of `Code.ensure_compiled/1`
  shape changes in 1.17 that the dispatcher depends on.
- `priv/erts_repository/MANIFEST.json` is the *fallback* (used when
  the upstream download fails and there's no cached copy). The
  primary source is `https://raw.githubusercontent.com/Lorenzo-SF/Batamanta---ERTS-repository/main/MANIFEST.json`
  pinned to `main`. The local copy is regenerated by the ERTS-repo
  CI, not by this repo.
- The `:integration` ExUnit tag gates the upstream URL hit; the
  compat test runs only with `mix test --include integration`.
  Without that flag, only the local-fallback tests run (which is
  what we want on a fresh clone).
- `Fetcher` uses `Process.get/put` for the manifest cache key
  (`{:batamanta_erts_manifest, :loaded}`) so a single `fetch/3`
  call doesn't re-download or re-parse within the same BEAM
  process. The on-disk cache (`get_cache_dir()/MANIFEST.json`) is
  the second tier, and `priv/erts_repository/MANIFEST.json` is the
  third tier. All three are loaded through `load_manifest_from_source/0`.
- `Batamanta.Target.manifest_key/1` is the single point of truth
  for upstream asset key names. The Fetcher delegates to it. If a
  new target is added, you add it to `Target.target_matrix`, give
  it a `manifest_key`, and the Fetcher/manifest_compat_test pair
  will catch any naming drift.

## Relevant Files

- `lib/batamanta.ex` (53 lines): top-level module, `@version 2.0.0-dev`.
- `lib/batamanta/application.ex` (13 lines): empty supervisor.
- `lib/batamanta/banner.ex` (441 lines): terminal image protocol
  detection — cosmetic, no semantic impact.
- `lib/batamanta/env_cleaner.ex` (349 lines): strips asdf/mise/kerl
  from PATH so build uses system Erlang matching the embedded ERTS.
- `lib/batamanta/escript_builder.ex` (137 lines): wraps
  `mix escript.build`.
- `lib/batamanta/escript_packager.ex` (458 lines): tarballs the
  escript + minimal ERTS subset. Has its own `get_erts_version/1`
  (was added in the 1.6 re-architecture).
- `lib/batamanta/logger.ex` (53 lines): banner-aware logger.
- `lib/batamanta/packager.ex` (563 lines): the release packager.
  Has `get_erts_version/1`, `prepare_erts/1` (no flatten, no
  per-script patches), `patch_bin_app_for_bundled_erlexec`
  (single `--erl-config` patch only).
- `lib/batamanta/release/step.ex` (16 lines): the mix release
  callback that produces the final binary.
- `lib/batamanta/run_script.ex` (126 lines): generates the `.run`
  entry-point script at build time with all env configuration
  (PATH, BINDIR, neutralisation, exec_mode routing, escript/release
  dispatch).
- `lib/batamanta/runner.ex` (35 lines): wraps `System.cmd/3` for
  testability.
- `lib/batamanta/rust_template.ex` (133 lines): copies the Rust
  dispenser template, injects the payload, runs `cargo build`.
- `lib/batamanta/target.ex` (514 lines): the target matrix and
  `manifest_key/1`. The single source of truth for upstream asset
  key names.
- `lib/batamanta/validator.ex` (269 lines): validates the OS ×
  arch × OTP × Elixir × mode combination. The
  `@min_otp_version` and `@min_elixir_version` constants are
  *more permissive* than the upstream floor for back-compat.
- `lib/batamanta/erts/fetcher.ex` (832 lines): download, retry,
  cache, extract, validate. Now uses `Jason.decode!/1` directly.
- `lib/batamanta/erts/libc_detector.ex` (278 lines): ldd + loader
  + `/etc/os-release` + `/proc/self/maps` for robust glibc/musl
  detection on Linux.
- `lib/mix/tasks/batamanta.ex` (962 lines): the `mix batamanta`
  CLI task. Coordinates detection, fetch, build, package.
- `lib/mix/tasks/batamanta.clean.ex` (~30 lines): wipes build
  artifacts while preserving the ERTS cache.
- `lib/mix/tasks/rust.test.ex` (~20 lines): `mix rust.test` —
  runs `cargo test` on the dispenser template.
- `priv/erts_repository/MANIFEST.json`: the offline fallback
  (third tier of the manifest cache). Regenerated from the
  upstream mirror by the ERTS-repo CI, not by this repo.
- `priv/rust_template/`: the Rust dispenser source. ~100 lines of
  `main.rs` that just extracts the payload and `exec()`s the
  `.run` script.

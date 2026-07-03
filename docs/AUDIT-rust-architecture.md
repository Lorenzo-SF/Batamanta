# batamanta Architecture Audit (v2 — full scope)

> Generated 2026-07-02 in response to recurring sys.config boot bugs.
> v2 after user pointed out I missed combinations documented in README/CHANGELOG.
> Scope: entire batamanta — Rust wrapper, Elixir packaging, env isolation, ERTS fetcher, libc detection, banner, image protocol, smoke tests.
> Status: **analysis only**, no code changes.

## TL;DR (corrected)

- **The Rust wrapper is one of ~6 substantial subsystems.** The actual surface area is much bigger than my v1 audit implied:
  - Rust wrapper (`main.rs`, 1149 lines) — boot dispatch
  - Elixir packaging (`packager.ex`, 481 lines) — release normalization, tar+zstd
  - Escript packaging (`escript_packager.ex`, 386 lines) — separate code path
  - ERTS fetcher (`erts/fetcher.ex`, 767 lines) — download, cache, retry, locking
  - Libc detector (`erts/libc_detector.ex`, 278 lines) — 4-method libc sniffing
  - Env cleaner (`env_cleaner.ex`, 349 lines) — version-manager isolation
  - Banner + image protocol (`banner.ex`, 441 lines) — 4 protocols, async streaming
  - Target matrix (`target.ex`, 426 lines) — 7 platforms, 2 libcs
- **Combinatorial matrix**: 7 platforms × ~45 OTP versions × 3 exec modes × 2 formats × 2 NIF/yes × 2 include_erts × 4 banner protocols × 4 libc-detection methods × 9 version-manager paths × 7 smoke-test categories ≈ **a few million leaf combinations**. My v1 estimate of 32k was wrong by 2-3 orders of magnitude.
- **The two recent bugs are not isolated incidents.** They're symptoms of a bigger pattern: hand-rolled infrastructure diverging from upstream (Mix release for boot, libc/glibc upstream for libc detection, terminal-protocol specs for banner). Every time upstream changes, batamanta silently lags.
- **The fundamental fix is still "stop reinventing upstream"**, but the scope is now: Rust boot layer (was the v1 recommendation), plus Elixir packaging conventions, plus env isolation, plus image protocol, plus ERTS management. Each one duplicates work that already exists somewhere.

---

## The smell in one paragraph (corrected)

batamanta is a **release-packaging framework**, not a single tool. It does (1) build-time ERTS provisioning with retry/cache/locking, (2) libc detection with 4 methods, (3) cross-platform release packaging with relative paths and self-contained tarballs, (4) env isolation from asdf/mise/kerl, (5) Rust wrapper for self-extracting single-binary distribution, (6) build banner with terminal image protocols, (7) umbrella project awareness. **Each subsystem was built because Elixir upstream didn't do it the way Lorenzo wanted** — and that's fair for some (banner is unique), but **two of the seven** (release packaging, env isolation) **diverged from upstream Mix release behavior**, and we paid for it with two cascading sys.config bugs in two weeks. The fix isn't just "collapse `run_with_erlexec`" — it's "audit each subsystem against its upstream and either adopt it or fork it intentionally with tests."

---

## Full combinatorial surface

batamanta must be correct across all of these:

| Subsystem | Variants | Source |
|---|---|---|
| **Platforms (advertised)** | `:ubuntu_22_04_x86_64`, `:ubuntu_22_04_arm64`, `:alpine_3_19_x86_64`, `:alpine_3_19_arm64`, `:macos_12_x86_64`, `:macos_12_arm64`, `:windows_x86_64` | README + `target.ex:40-104` |
| **Platforms (actually shipped)** | `amd64-glibc`, `amd64-musl`, `arm64-glibc`, `arm64-musl`, `darwin-arm64` | `priv/erts_repository/MANIFEST.json` |
| **Platforms (binary built)** | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`, `x86_64-apple-darwin`, `aarch64-apple-darwin`, `x86_64-pc-windows-msvc` | `target.ex` + `rust_template.ex:10-11` |
| **DRIFT** | No `darwin-x86_64` tarball. No Windows tarball. `windows_x86_64` target advertised but unsupported. | compare README/MANIFEST/rust_template |
| **OTP versions** | OTP-25.0 → 28.2.5.xx (~45 patch releases) | `MANIFEST.json` |
| **Exec modes** | `:cli`, `:tui`, `:daemon` | `mix.exs` config |
| **Boot per mode** | `:cli` → `start_clean.boot` + `-eval <Mod>.main([...])` + `-s init stop`; `:daemon`/`:tui` → `start.boot` + `-extra --` | `main.rs:668-746` |
| **Formats** | `:release`, `:escript` (auto-detected from `escript: [main_module: ...]`) | README, `rust_template.ex:42` |
| **NIFs / native code** | yes (Rust NIFs, tree-sitter, etc.) / no | consumer app |
| **Include ERTS** | `true` (kernel in `release/lib/`) / `false` (kernel in `release/erts-X.Y/lib/`) | consumer app config |
| **ERTS layout detection** | 4 ways: `<rel>/bin/erlexec`, `<rel>/erts-X.Y/bin/erlexec`, `<rel>/erts/bin/erlexec`, fallback recursive | `main.rs:579-584` |
| **Libc** | glibc (gnu) / musl / msvc (Windows) / unknown fallback | `libc_detector.ex` |
| **Libc detection methods** | `ldd --version` → dynamic loader (`/lib/ld-musl*.so` vs `/lib64/ld-linux*.so`) → `/etc/os-release` → `/proc/self/maps` | `libc_detector.ex:detect/0` |
| **musl distros whitelist** | alpine, void, postmarketos | `libc_detector.ex` constants |
| **Env isolation vars** | `ERL_FLAGS`, `ERL_AFLAGS`, `ERL_ZFLAGS`, `ASDF_ERLANG_VERSION`, `MISE_ERLANG_VERSION`, `KERL_ENABLE_PROMPT` | `main.rs` + `env_cleaner.ex` |
| **Version-manager paths** | `.asdf`, `asdf/shims`, `.mise`, `mise/shims`, `kerl`, `.evm`, `goenv`, `.rbenv`, `pyenv`, `nvm`, `rvenv` | `env_cleaner.ex:226-242` |
| **Banner image protocols** | kitty (kitty/wezterm/ghostty/konsole), iterm2 (iTerm2), sixel (alacritty/foot/vscode), ascii (fallback via img2txt), kitty with image-id swaps | `banner.ex:402-441` |
| **Banner assets** | `batamantaman.png` (default), `_happy`, `_sad`, `_no_title`, `-sit`, `-sit_no_title` (6 PNGs) | `assets/` |
| **Banner modes** | `:streaming` (image + live messages), `:text_only` (fallback) | `banner.ex:14-37` |
| **Terminal escape sequences** | `\e_G...e\` (kitty), `\e]1337;...\a` (iterm2), `\e[NA`, `\e[NB`, `\e[s`, `\e[u`, `\e[2J`, etc. | `banner.ex` throughout |
| **Concurrent builds** | file-based locking per `(otp_version, platform_key)` | `fetcher.ex:79-110` |
| **Download retry policy** | 3 retries, 1000ms base delay exponential | `fetcher.ex:30-32` |
| **Cross-compilation** | from macOS to Linux (glibc/musl, x86_64/arm64); from any host to any target via `--erts-target` | README + `target.ex` |
| **Umbrella mode** | sub-apps with individual `batamanta:` configs in `apps/`; each built independently | README + `rust_template.ex` (umbrella path) |
| **Escript mode** | `mix escript.build` → batamanta bundles minified ERTS → ~20MB binary | `escript_packager.ex` |
| **smoke test categories** | cli, daemon, escript, escript_otp26, release_otp27, release_nif, tui (7 tests) | `smoke_tests/` |
| **Docker matrix** | glibc base image (Debian/Ubuntu) + musl base image (Alpine); both build smoke_tests/test_cli | `docker_matrix_simple.sh` |

The truly cross-producted surface — every leaf combination must boot correctly — is well into six figures.

---

## Subsystem-by-subsystem findings

### A. Rust boot wrapper (`main.rs`, 1149 lines)

**Status**: **2 cascading bugs in 2 weeks, plus 6 `FIX:` comments** indicating prior divergence.

**Reimplements what Mix release's `bin/<app>` script does correctly**:
- Setting `ROOTDIR`/`BINDIR`/`ERL_LIBS`/`RELEASE_ROOT`/`RELEASE_PROG`/`RELEASE_SYS_CONFIG`/`RELEASE_VM_ARGS`
- Picking `start.boot` vs `start_clean.boot` based on mode
- Passing `-config <sys.config>` and `-args_file <vm.args>`
- Calling `erlexec` with the right flags
- Handling daemon detach via fork+setsid

**Why it diverges**:
- Lines 700-870 build the entire erlexec argv by hand
- Lines 769-784 (daemon) and 821-835 (CLI) set the same 13 env vars in two places
- Lines 717-738 manually escape user args for Erlang binary syntax (`<<"text">>`) instead of letting the boot script pass them through
- Lines 668-696 implement a custom `start.boot` selector that the standard script already does

**Cost**: every Mix release config-loading enhancement breaks batamanta. Two in a row, more likely.

**Fix**: collapse to ~80 lines that `fork + setsid + execve` the bundled `release/bin/<app>`. Keep only: payload extraction (Mix release can't), env neutralization (one helper), PATH injection (one helper).

---

### B. Elixir packaging (`packager.ex`, 481 lines)

**Status**: **mostly OK**, but contains a **layout-flattening** step (`flatten_nested_erts`) that breaks the standard Mix release ERTS layout (`erts-X.Y/bin/`) and forces the Rust wrapper to compensate with a 4-way `find_file` chain.

**The chain that creates the smell**:
1. `packager.ex:84-85` flattens `<erts>/erts-X.Y/bin/erlexec` → `<erts>/bin/erlexec`
2. Rust wrapper's `main.rs:579-584` then needs 4 fallback searches for erlexec because flattened layout doesn't match the standard `bin/<app>` script's expectations
3. `packager.ex:243-262` (`find_best_boot`) is yet another search for `*.boot` files
4. `main.rs:668-696` is yet another search for `start.boot` vs `start_clean.boot`

**Cost**: 4 separate file-system search algorithms that all try to solve "where is the ERTS layout?" — and any of them can disagree.

**Fix**: don't flatten. Set `include_erts: false` and pass `ROOTDIR=<release>/erts-X.Y` via the bundled ERTS cache. The Mix release `bin/<app>` then works unmodified.

---

### C. ERTS fetcher (`erts/fetcher.ex`, 767 lines)

**Status**: **mostly OK**, but the `MANIFEST.json` is a **single point of failure** for the entire matrix (5 platforms × 45 OTP versions × 4 libc). Adding a new platform/OTP version requires manually editing this file.

**Drift observed**:
- `MANIFEST.json` has `darwin-arm64` but NOT `darwin-x86_64`
- `MANIFEST.json` has NO Windows tarballs
- `target.ex` advertises `:macos_12_x86_64` and `:windows_x86_64` as targets
- README claims Windows is supported

**Cost**: users run `mix batamanta --erts-target macos_12_x86_64` and get a confusing error. Or run `mix batamanta --erts-target windows_x86_64` and find no pre-built tarball.

**Fix**: clearly separate "advertised targets" from "shipped tarballs". Either ship the missing tarballs (requires building them with a cross-compilation toolchain) OR remove the unsupported targets from `target.ex`.

---

### D. Libc detector (`erts/libc_detector.ex`, 278 lines)

**Status**: **robust**, 4 fallback methods, musl distro whitelist. Good design.

**Minor concerns**:
- Detection runs every build (no caching). For a CI farm running thousands of builds, this is a small CPU waste.
- `/proc/self/maps` fallback is "advanced" but undocumented — what edge case does it solve that the other three don't?

**No action needed.**

---

### E. Env cleaner (`env_cleaner.ex`, 349 lines)

**Status**: **mostly OK**, three env-construction modes (`clean_env`, `erts_env`, `build_env`) with documented differences. The `build_env/1` mode is the safest and most-used.

**Minor concerns**:
- `version_manager_path?/1` uses 10 `String.contains?` checks. Faster to compile a regex once.
- `build_env/1` uses `System.get_env()` which on Windows has case-sensitivity quirks (`Path` vs `PATH`).

**No action needed.**

---

### F. Banner + image protocol (`banner.ex`, 441 lines)

**Status**: **largest single file in the system**, implements 4 terminal image protocols from scratch with raw escape sequences. **This is the module with the most "reinvented the wheel" character** — there are crates like `viuer` and `termimage` that handle cross-protocol image rendering in Rust, and even Elixir libs like `image` that do some of this. But batamanta chose to hand-roll it in Elixir because it needed fine-grained control over the streaming progress display alongside the image.

**Concerns**:
- 4 protocols × multiple terminal emulators × 6 PNG assets = a lot of combinations to test visually
- Most users won't see this code; only when `show_banner: true`
- Cursor positioning uses `\e[s` + `\e[u` (save/restore) which works on most terminals but not all (notably some Windows Terminal versions)

**Fix consideration**: low priority. It's an end-user UX feature, not a correctness feature. Leave it.

---

### G. Target matrix (`target.ex`, 426 lines)

**Status**: **mostly OK**, single source of truth for the 7 advertised targets.

**Drift**:
- README says `windows_x86_64` ✅ supported — but `MANIFEST.json` has no Windows tarballs
- README says `darwin-x86_64` — but `MANIFEST.json` only has `darwin-arm64`
- `target.ex:294` `get_target_for_libc/1` hardcodes `alpine_3_19_x86_64` for musl and `ubuntu_22_04_x86_64` for gnu — these are amd64 defaults. If running on aarch64 host with `force_libc: musl`, the suggested fix command is wrong (should be `alpine_3_19_arm64`)

**Fix**: add a Windows tarball pipeline OR remove `:windows_x86_64` from `valid_targets/0`. Add `darwin-x86_64` tarball. Make `get_target_for_libc/1` arch-aware.

---

### H. Smoke tests (`smoke_tests/`, 7 tests)

**Status**: **good coverage for the boot layer**, weak coverage for everything else.

**Has**:
- `test_cli`, `test_daemon`, `test_tui`, `test_escript`, `test_release_nif`, `test_release_otp27`, `test_escript_otp26`
- Each is a small Mix project with its own `mix.exs`

**Missing**:
- No `smoke_test` for `windows_x86_64`
- No `smoke_test` for `darwin-x86_64`
- No `smoke_test` for `umbrella` builds
- No `smoke_test` for cross-compilation (build Linux from Mac)
- The Rust unit tests cover only file-path utilities; nothing about actual boot behavior

**Fix**: add the missing smoke tests. Wire them into CI via the existing `smoke_test_runner.sh`.

---

## Architectural options (expanded)

### Option A: Collapse Rust boot wrapper to `exec` the bundled `bin/<app>`

**Scope**: subsystem A only.

**Pros**: same as v1 — eliminates the boot-divergence bug class, ~1100 → ~80 lines.

**Cons**:
- Doesn't address subsystems B (packager flattening), C (fetcher drift), G (target drift)
- Still leaves 5 other subsystems as-is

**Effort**: 1-2 days.

**Risk**: low.

**Recommendation**: **YES, but it's only 20% of the actual surface.**

### Option B: Consolidate each subsystem against its upstream

**Scope**: A (Rust boot) + B (packager) + C (fetcher) + G (target matrix).

**What it is**: for each subsystem, decide "do we adopt upstream's behavior?" or "do we intentionally fork it?". Apply consistently.

- **A → adopt**: `exec` the bundled `bin/<app>`. Stop reinventing.
- **B → adopt**: stop flattening `erts-X.Y/`. Trust the standard layout.
- **C → reconcile**: make `MANIFEST.json` match what `target.ex` advertises, or vice versa.
- **G → reconcile**: same as C.

**Pros**:
- Each subsystem aligns with its upstream or commits to its fork deliberately.
- Tests can be written per subsystem with clear contracts.
- Future upstream changes propagate (where adopted) or break loudly (where forked, with a regression test).

**Cons**:
- Bigger refactor — touches 4 subsystems, multiple files
- Risk of breaking consumers mid-refactor; needs feature flags or staged rollout
- Some forks (banner, fetcher retry/lock) are intentional and good — don't lose them

**Effort**: 1-2 weeks.

**Risk**: medium. Need a feature branch and a beta cycle with all known consumers (delfos, pote, candil ecosystem).

**Recommendation**: **THIS is the real fix.** Option A alone doesn't address the other 80%.

### Option C: Status quo + comprehensive smoke tests

**Scope**: subsystems A, B, C, G via testing.

**What it is**: keep all subsystems, add smoke tests that catch regressions like the sys.config bug.

**Pros**: catches regressions.

**Cons**: doesn't prevent divergence, just catches it after.

**Effort**: 3-5 days.

**Risk**: low.

**Recommendation**: do this IN ADDITION TO B, not instead.

---

## Recommendation

**Option B + Option C**: consolidate each subsystem against its upstream, AND add the missing smoke tests so any future regression gets caught.

Specifically, in priority order:

1. **Stop the bleeding** (1-2 days): Option A on the Rust boot layer. This is the source of the immediate recurring pain. Ship as `1.7.0` once smoke-tested with delfos.
2. **Stop flattening ERTS** (2-3 days): Option B on subsystem B. Drop `flatten_nested_erts`. Trust the standard layout. Verify all 7 smoke tests still pass.
3. **Reconcile targets** (1 day): Option B on C+G. Either ship missing tarballs (darwin-x86_64, windows) OR remove unsupported targets from `valid_targets/0`. Document the current coverage in README.
4. **Add the missing smoke tests** (2-3 days): Option C. windows, darwin-x86_64, umbrella, cross-compile.
5. **Audit banner** (1 day): confirm image protocols still work after the boot layer change (banner doesn't directly touch boot, but the wrapper's TTY mode does — banner.ex uses `IO.write` directly to stdout, independent of Rust wrapper).

What I'd skip:
- **Banner rewrite** — it works, it's well-isolated, the cost-benefit isn't there.
- **Env cleaner rewrite** — it's robust, three modes for three use cases, good design.
- **Fetcher retry/lock rewrite** — already does exponential backoff and file-based locking, that's not reinventable from upstream.

---

## Revised file:line references

**Subsystem A — Rust boot**:
- `priv/rust_template/src/main.rs:170-226` — `main()` (extract → dispatch by format)
- `priv/rust_template/src/main.rs:249-432` — `run_escript()` (~180 lines, escript path)
- `priv/rust_template/src/main.rs:437-548` — `create_escript_wrapper()` (shell-script generator for escript)
- `priv/rust_template/src/main.rs:559-882` — `run_with_erlexec()` (~320 lines, release path) **← bug source**
- `priv/rust_template/src/main.rs:954-1148` — Rust unit tests (17 tests, file-lookup only)

**Subsystem B — Packaging**:
- `lib/batamanta/packager.ex:1-481` — Elixir packaging (flatten, tar, zstd, normalize) **← smell source**
- `lib/batamanta/packager.ex:84-85` — `flatten_nested_erts/1` (root of subsystem B's smell)
- `lib/batamanta/packager.ex:243-262` — `find_best_boot/2` (yet another boot-file search)
- `lib/batamanta/escript_packager.ex:1-386` — separate escript code path
- `lib/batamanta/escript_builder.ex:1-177` — escript building

**Subsystem C — ERTS fetcher**:
- `lib/batamanta/erts/fetcher.ex:1-767` — download, cache, retry, locking
- `priv/erts_repository/MANIFEST.json` — 5 platforms × 45 OTP versions × file matrix **← drift source**

**Subsystem D — Libc detection**:
- `lib/batamanta/erts/libc_detector.ex:1-278` — 4-method libc sniffing

**Subsystem E — Env isolation**:
- `lib/batamanta/env_cleaner.ex:1-349` — version-manager isolation

**Subsystem F — Banner**:
- `lib/batamanta/banner.ex:1-441` — 4 image protocols, async streaming
- `assets/` — 6 PNG banner assets

**Subsystem G — Target matrix**:
- `lib/batamanta/target.ex:1-426` — 7 targets, 2 libcs **← drift source**

**Smoke tests**:
- `smoke_tests/test_cli`, `test_daemon`, `test_escript`, `test_release_nif`, `test_release_otp27`, `test_tui`, `test_escript_otp26` (7)
- `docker_matrix_simple.sh` — Docker-based glibc/musl matrix
- `smoke_test_runner.sh` — runs them all

**Other supporting files** (no audit needed, just listed for completeness):
- `lib/batamanta/runner.ex` — 35 lines, task orchestration
- `lib/batamanta/validator.ex` — 264 lines, pre-build validation
- `lib/batamanta/application.ex` — 13 lines, supervisor
- `lib/batamanta/logger.ex` — 53 lines, log formatting
- `lib/batamanta/release/step.ex` — 16 lines, release step interface

---

## Revised commit archaeology

- `6c7a8ef` — `chore(deps): pin batamanta to the release/rootdir+umbrella fix branch` — already a "divergence from upstream" branch, confirming this is a recurring pattern.
- `693736d` — `Fix/release rootdir and umbrella paths (#15)` — same bug class, different sym.
- `83c4580` — our `--erl-config` → `-config` fix (subsystem A).
- `bf77112` — our `RELEASE_SYS_CONFIG` without `.config` fix (subsystem A).
- Plus many from CHANGELOG showing similar recurring fixes in subsystems B (umbrella paths), E (env isolation), G (target matrix drift).

**Three fixes in 3 weeks in subsystem A alone. Several more in other subsystems over the project lifetime.** The pattern is established; the audit is the chance to break it.

---

## Appendix: what I got wrong in v1

- **Underestimated combinatorics by 2-3 orders of magnitude.** 32k → millions. Many subsystems I didn't even consider in v1.
- **Treated batamanta as "just a Rust wrapper".** It's actually 8 substantial subsystems, of which the Rust wrapper is one.
- **Missed the README-vs-MANIFEST drift.** README claims 7 platforms with Windows + darwin-x86_64; MANIFEST only ships 5. Either ship the missing tarballs or remove the targets.
- **Missed the umbrella mode.** README documents it; CHANGELOG has a whole section on it.
- **Missed the smoke test matrix.** 7 smoke tests across cli/daemon/tui/escript/release_nif/release_otp27/escript_otp26.
- **Missed the banner / image protocol complexity.** 441 lines, 4 protocols, 6 PNGs.
- **Missed env_cleaner.ex entirely.** 349 lines, three env modes, 10 version-manager detectors.

The v1 audit wasn't wrong about Option A — it's still the right move for subsystem A. But treating Option A as "the fix" missed that the same architectural smell exists in 3-4 other subsystems.

---

## v1 audit (superseded)

The previous audit is preserved in git history (`docs/AUDIT-rust-architecture.md`, commit before this v2). It remains accurate **for the Rust wrapper specifically** but does not cover the full project. Reference it for Option A details.
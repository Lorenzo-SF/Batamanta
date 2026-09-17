#!/usr/bin/env bash
#===============================================================================
# BEAM-daemon-mode smoke test runner.
#
# Expects the test_beam_daemon binary to be already built (the CI workflow
# runs `mix batamanta` in the project before invoking this runner). Locally
# or in a fresh checkout, this script will rebuild the binary for you —
# that's a single-shot path; in CI it's just the warm-path benchmark.
#
# Exercises the binary with N invocations. The first invocation pays the
# BEAM boot cost; the remaining N-1 should hit the warm BEAM in single-digit
# milliseconds. Total wall-time must be well under the same loop in legacy
# mode (which would pay boot cost N times).
#
# This script is the safety net batamanta-daemon-mode-spec.md asks for in
# §"Cómo probarlo" (point 1: Benchmark de arranque en frío vs. dispatch
# en caliente).
#
# Usage:
#     ./smoke_tests/test_beam_daemon_runner.sh [iterations]
#
# Env vars:
#     SKIP_BUILD=1   don't run `mix batamanta`; assume binary is present
#                    (CI workflow sets this).
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/test_beam_daemon"
ITERATIONS="${1:-15}"

# An overall wall-time cap. The CI smoke step passes us 60s as
# TIMEOUT (see smoke_test_runner.sh). Without a cap this script will
# happily iterate 15 times even when each invocation stalls — which
# in CI lingo means the job hits its 6-hour soft limit while one
# stalled binary sits in a syscall. Default 90s gives us one slow
# cold-boot (~5-30s) plus 14 fast warm calls; raise it if you need
# more iterations via the BATAMANTA_DAEMON_SMOKE_TIMEOUT env var.
SMOKE_TIMEOUT="${BATAMANTA_DAEMON_SMOKE_TIMEOUT:-90}"

cd "$SCRIPT_DIR/.."

# Find the resulting binary. If missing, try to build it (unless the
# caller told us the binary is already there).
BIN="$(find "$PROJECT_DIR" -maxdepth 1 -name 'test_beam_daemon-*' -type f | head -n1)"

if [[ -z "$BIN" && "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "==> Building test_beam_daemon smoke binary (mix batamanta)..."
    (cd "$PROJECT_DIR" && mix deps.get >/dev/null 2>&1 || true)
    (cd "$PROJECT_DIR" && mix batamanta 2>&1 | tail -30)
    BIN="$(find "$PROJECT_DIR" -maxdepth 1 -name 'test_beam_daemon-*' -type f | head -n1)"
fi

if [[ -z "$BIN" ]]; then
    echo "FAIL: no binary produced by mix batamanta" >&2
    exit 1
fi
echo "==> Binary: $BIN"

# Run N invocations with daemon mode enabled.
export BATAMANTA_BEAM_ALIVE=30000

echo "==> Running $ITERATIONS invocations (overall cap: ${SMOKE_TIMEOUT}s)..."
TOTAL_START_NS=$(date +%s%N)
TOTAL_START_S=$(date +%s)
LAST_OUTPUT=""
for i in $(seq 1 "$ITERATIONS"); do
    # Per-call timeout so a single hung binary can't stall the whole
    # smoke run. The first call pays the cold-boot cost so we give it
    # 60s; subsequent warm calls finish in ms.
    PER_CALL_TIMEOUT=60
    if [[ "$i" -gt 1 ]]; then
        PER_CALL_TIMEOUT=10
    fi
    OUT=$(timeout "$PER_CALL_TIMEOUT" "$BIN" "iter=$i" 2>&1) || {
        rc=$?
        echo "FAIL: invocation $i exited non-zero (rc=$rc, per-call-timeout=${PER_CALL_TIMEOUT}s)" >&2
        echo "$OUT" >&2
        exit 1
    }
    if [[ "$i" -eq 1 ]]; then
        FIRST_OUTPUT="$OUT"
    fi
    LAST_OUTPUT="$OUT"

    # Stop iterating if we'd blow past the overall cap; still pass if
    # we've got at least 2 successful calls (cold + warm).
    ELAPSED=$(( $(date +%s) - TOTAL_START_S ))
    if (( ELAPSED > SMOKE_TIMEOUT )) && (( i >= 3 )); then
        echo "==> Hit overall smoke cap (${SMOKE_TIMEOUT}s) after $i invocations; stopping early."
        break
    fi
done
TOTAL_END_NS=$(date +%s%N)
TOTAL_MS=$(( (TOTAL_END_NS - TOTAL_START_NS) / 1000000 ))

echo "==> Total wall-time: ${TOTAL_MS}ms across $ITERATIONS invocations"

# Sanity: first invocation should report "invocation: 1", last "N".
if ! grep -q "invocation: 1" <<< "$FIRST_OUTPUT"; then
    echo "FAIL: first invocation didn't show invocation: 1" >&2
    echo "$FIRST_OUTPUT" >&2
    exit 1
fi
if ! grep -q "invocation: $ITERATIONS" <<< "$LAST_OUTPUT"; then
    echo "FAIL: last invocation didn't show invocation: $ITERATIONS" >&2
    echo "$LAST_OUTPUT" >&2
    exit 1
fi

# Time individual invocations AFTER the first (warm path).
echo "==> Timing warm-path invocations (iterations 2..$ITERATIONS)..."
WARM_START_NS=$(date +%s%N)
for i in $(seq 2 "$ITERATIONS"); do
    timeout 10 "$BIN" "iter=$i" >/dev/null 2>&1
done
WARM_END_NS=$(date +%s%N)
WARM_MS=$(( (WARM_END_NS - WARM_START_NS) / 1000000 ))
PER_CALL_MS=$(( WARM_MS / (ITERATIONS - 1) ))

echo "==> Warm-path total: ${WARM_MS}ms (${PER_CALL_MS}ms per call)"

# Daemon-mode gate: warm-path calls must average well under 100ms. A
# legacy boot pays ~200-500ms per call, so this is a generous upper
# bound. If we exceed this, the daemon isn't being hit (env var issue)
# or BEAM startup overhead is unexpectedly high.
if [[ "$PER_CALL_MS" -gt 100 ]]; then
    echo "WARN: warm-path calls averaged ${PER_CALL_MS}ms (>100ms)." >&2
    exit 2
fi

echo "==> Daemon-mode smoke test PASSED."

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

echo "==> Running $ITERATIONS invocations..."
TOTAL_START=$(date +%s%N)
for i in $(seq 1 "$ITERATIONS"); do
    OUT=$("$BIN" "iter=$i" 2>&1) || {
        echo "FAIL: invocation $i exited non-zero" >&2
        echo "$OUT" >&2
        exit 1
    }
    if [[ "$i" -eq 1 ]]; then
        FIRST_OUTPUT="$OUT"
    fi
done
TOTAL_END=$(date +%s%N)
TOTAL_MS=$(( (TOTAL_END - TOTAL_START) / 1000000 ))

echo "==> Total wall-time: ${TOTAL_MS}ms across $ITERATIONS invocations"

# Sanity: first invocation should report "invocation: 1", last "N".
if ! grep -q "invocation: 1" <<< "$FIRST_OUTPUT"; then
    echo "FAIL: first invocation didn't show invocation: 1" >&2
    echo "$FIRST_OUTPUT" >&2
    exit 1
fi
LAST_OUTPUT="$OUT"
if ! grep -q "invocation: $ITERATIONS" <<< "$LAST_OUTPUT"; then
    echo "FAIL: last invocation didn't show invocation: $ITERATIONS" >&2
    echo "$LAST_OUTPUT" >&2
    exit 1
fi

# Time individual invocations AFTER the first (warm path).
echo "==> Timing warm-path invocations (iterations 2..$ITERATIONS)..."
WARM_START=$(date +%s%N)
for i in $(seq 2 "$ITERATIONS"); do
    "$BIN" "iter=$i" >/dev/null 2>&1
done
WARM_END=$(date +%s%N)
WARM_MS=$(( (WARM_END - WARM_START) / 1000000 ))
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

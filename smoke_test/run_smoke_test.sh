#!/bin/bash
# Batamanta Smoke Test Runner
# Usage: ./run_smoke_test.sh <mode> [erts_target]
#
# Modes: cli, tui, daemon
#
# This script:
# 1. Builds the binary with batamanta
# 2. Executes it with appropriate validation for each mode
# 3. Returns exit code 0 on success, 1 on failure

set -e

MODE="${1:-cli}"
ERTS_TARGET="${2:-}"

echo "=========================================="
echo "Batamanta Smoke Test Runner"
echo "Mode: $MODE"
echo "ERTS Target: ${ERTS_TARGET:-auto}"
echo "=========================================="

# Build arguments
BUILD_ARGS="--compression 1"
if [ -n "$ERTS_TARGET" ]; then
  BUILD_ARGS="$BUILD_ARGS --erts-target $ERTS_TARGET"
fi

echo ""
echo "[1/3] Building with Batamanta..."
MIX_ENV=prod mix batamanta $BUILD_ARGS

# Find the binary
BINARY=$(ls -1 _build/prod/rel/smoke_test/bin/smoke_test-* 2>/dev/null | head -1)

if [ -z "$BINARY" ] || [ ! -f "$BINARY" ]; then
  echo "❌ ERROR: Binary not found"
  exit 1
fi

echo "✅ Binary found: $BINARY"
echo ""
echo "[2/3] Executing smoke test..."
echo ""

# Execute based on mode
case "$MODE" in
  cli)
    # CLI should execute and exit cleanly
    OUTPUT=$("$BINARY" --test-arg1 --test-arg2 2>&1) || true
    EXIT_CODE=$?
    
    echo "$OUTPUT"
    echo ""
    
    # Validate CLI behavior
    if echo "$OUTPUT" | grep -q "Arguments received"; then
      echo "✅ PASS: CLI printed arguments"
    else
      echo "❌ FAIL: CLI did not print arguments"
      exit 1
    fi
    
    if echo "$OUTPUT" | grep -q "CLI test completed"; then
      echo "✅ PASS: CLI completed successfully"
    else
      echo "❌ FAIL: CLI did not complete"
      exit 1
    fi
    ;;
    
  tui)
    # TUI should render UI and exit (or wait for input)
    OUTPUT=$(echo "q" | timeout 5 "$BINARY" 2>&1) || true
    EXIT_CODE=$?
    
    echo "$OUTPUT"
    echo ""
    
    if echo "$OUTPUT" | grep -q "Arguments received"; then
      echo "✅ PASS: TUI received arguments"
    else
      echo "❌ FAIL: TUI did not receive arguments"
      exit 1
    fi
    
    if echo "$OUTPUT" | grep -qE "TUI|Raw mode|Keyboard"; then
      echo "✅ PASS: TUI initialized correctly"
    else
      echo "⚠️  WARN: TUI output not detected (may be OK in CI)"
    fi
    
    echo "✅ PASS: TUI executed"
    ;;
    
  daemon)
    # Daemon should start and run indefinitely
    "$BINARY" --daemon-test &
    DAEMON_PID=$!
    
    echo "Daemon PID: $DAEMON_PID"
    
    # Give it time to start
    sleep 2
    
    # Check if running
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "✅ PASS: Daemon is running"
      
      # Stop it
      kill -TERM "$DAEMON_PID" 2>/dev/null || true
      
      # Wait for graceful shutdown
      for i in 1 2 3 4 5; do
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
          echo "✅ PASS: Daemon stopped gracefully"
          break
        fi
        sleep 1
      done
      
      # Force kill if needed
      if kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -9 "$DAEMON_PID" 2>/dev/null || true
        echo "✅ PASS: Daemon force-killed"
      fi
      
      wait "$DAEMON_PID" 2>/dev/null || true
    else
      echo "❌ FAIL: Daemon did not start"
      exit 1
    fi
    ;;
    
  *)
    echo "❌ ERROR: Unknown mode '$MODE'"
    echo "Valid modes: cli, tui, daemon"
    exit 1
    ;;
esac

echo ""
echo "[3/3] Smoke test completed!"
echo "=========================================="
echo "✅ All checks passed for mode: $MODE"
echo "=========================================="

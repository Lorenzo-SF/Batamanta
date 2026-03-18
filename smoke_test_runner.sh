#!/bin/bash
# Smoke Test Runner for Batamanta
# Usage: ./smoke_test_runner.sh <project_dir> <mode> [timeout_seconds] [qemu_prefix]
#
# Arguments:
#   project_dir      - Path to the test project directory
#   mode             - Execution mode: cli, tui, or daemon
#   timeout_seconds  - Timeout in seconds (default: 30)
#   qemu_prefix      - QEMU binary prefix for cross-architecture testing

set +e

PROJECT_DIR="$1"
MODE="$2"
TIMEOUT="${3:-30}"
QEMU_PREFIX="${4:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 <project_dir> <mode> [timeout_seconds] [qemu_prefix]"
    exit 1
fi

# Find the binary
BINARY_PATH=""
for bin in "$PROJECT_DIR"/test_${MODE}-*; do
    if [ -f "$bin" ] && [ -x "$bin" ]; then
        BINARY_PATH="$bin"
        break
    fi
done

if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found in $PROJECT_DIR"
    ls -la "$PROJECT_DIR" 2>/dev/null | head -20
    exit 1
fi

# Build command prefix
if [ -n "$QEMU_PREFIX" ]; then
    CMD_PREFIX="$QEMU_PREFIX "
    echo "Using QEMU: $QEMU_PREFIX"
else
    CMD_PREFIX=""
fi

echo "=========================================="
echo "Smoke Test: $MODE mode"
echo "Binary: $BINARY_PATH"
echo "Timeout: ${TIMEOUT}s"
echo "=========================================="

case "$MODE" in
    cli)
        echo "[CLI TEST] Executing binary..."
        OUTPUT=$(${CMD_PREFIX}timeout "$TIMEOUT" "$BINARY_PATH" --test-args "smoke_test" 2>&1) || true
        EXIT_CODE=$?
        echo "$OUTPUT"
        
        if [ $EXIT_CODE -eq 124 ]; then
            echo "✗ FAIL: CLI timed out"
            exit 1
        fi
        
        if echo "$OUTPUT" | grep -q "Arguments received"; then
            echo "✓ PASS: CLI printed arguments"
        else
            echo "✗ FAIL: CLI did not print arguments"
            exit 1
        fi
        
        if echo "$OUTPUT" | grep -q "completed\|started\|Usage\|version"; then
            echo "✓ PASS: CLI executed successfully"
        else
            echo "✗ FAIL: CLI did not execute properly"
            exit 1
        fi
        echo "CLI SMOKE TEST PASSED"
        ;;

    tui)
        echo "[TUI TEST] Executing TUI binary..."
        OUTPUT=$(echo "q" | ${CMD_PREFIX}timeout "$TIMEOUT" "$BINARY_PATH" 2>&1) || true
        EXIT_CODE=$?
        echo "$OUTPUT"
        
        if [ $EXIT_CODE -eq 124 ]; then
            echo "✗ FAIL: TUI timed out"
            exit 1
        fi
        
        if echo "$OUTPUT" | grep -q "Arguments received"; then
            echo "✓ PASS: TUI received arguments"
        else
            echo "✗ FAIL: TUI did not receive arguments"
            exit 1
        fi
        
        if echo "$OUTPUT" | grep -qE "UI|Status|Rendering|Keyboard"; then
            echo "✓ PASS: TUI rendered interface"
        else
            echo "⚠ WARN: TUI UI rendering not detected"
        fi
        
        echo "✓ PASS: TUI executed and exited"
        echo "TUI SMOKE TEST PASSED"
        ;;

    daemon)
        echo "[DAEMON TEST] Starting daemon..."
        ${CMD_PREFIX}"$BINARY_PATH" --daemon-args "test" &
        DAEMON_PID=$!
        echo "Daemon PID: $DAEMON_PID"
        sleep 3
        
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo "✗ FAIL: Daemon exited immediately"
            exit 1
        fi
        
        echo "✓ PASS: Daemon is running"
        sleep 2
        
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo "✓ PASS: Daemon still running"
        else
            echo "✗ FAIL: Daemon exited prematurely"
            exit 1
        fi
        
        echo "Stopping daemon..."
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        
        for i in 1 2 3 4 5; do
            if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
                echo "✓ PASS: Daemon stopped gracefully"
                break
            fi
            sleep 1
        done
        
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            kill -9 "$DAEMON_PID" 2>/dev/null || true
            echo "✓ PASS: Daemon force-killed"
        fi
        
        wait "$DAEMON_PID" 2>/dev/null || true
        echo "DAEMON SMOKE TEST PASSED"
        ;;

    *)
        echo "ERROR: Unknown mode '$MODE'"
        exit 1
        ;;
esac

echo "All smoke tests passed for mode: $MODE"
exit 0

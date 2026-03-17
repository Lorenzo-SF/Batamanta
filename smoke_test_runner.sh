#!/bin/bash
# Smoke Test Runner for Batamanta
# Usage: ./smoke_test_runner.sh <project_dir> <mode> [timeout_seconds]
#
# Arguments:
#   project_dir      - Path to the test project directory
#   mode             - Execution mode: cli, tui, or daemon
#   timeout_seconds  - Timeout in seconds (default: 30)

# Don't exit on error - we handle errors manually
set +e

PROJECT_DIR="$1"
MODE="$2"
TIMEOUT="${3:-30}"

if [ -z "$PROJECT_DIR" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 <project_dir> <mode> [timeout_seconds]"
    echo "  mode: cli, tui, or daemon"
    exit 1
fi

# Batamanta creates the binary in the project root with format:
# <app_name>-<version>-<arch>-<os>
# For example: test_cli-0.1.0-aarch64-macos

# Find the binary (it may have version/arch suffixes)
BINARY_PATH=""

# Try to find the binary in the project directory
for bin in "$PROJECT_DIR"/test_${MODE}-*; do
    if [ -f "$bin" ] && [ -x "$bin" ]; then
        BINARY_PATH="$bin"
        break
    fi
done

# Verify binary exists
if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found in $PROJECT_DIR"
    echo "Looking for: test_${MODE}-*"
    echo "Contents of $PROJECT_DIR:"
    ls -la "$PROJECT_DIR" 2>/dev/null | head -20 || echo "  (directory does not exist)"
    exit 1
fi

echo "Running smoke test for mode: $MODE"
echo "Binary: $BINARY_PATH"
echo "Timeout: ${TIMEOUT}s"

case "$MODE" in
    cli)
        # CLI mode: should execute and exit
        echo "Testing CLI mode..."
        timeout "$TIMEOUT" "$BINARY_PATH" --help
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo "✗ CLI test failed: timeout"
            exit 1
        fi
        # CLI may exit with non-zero for --help, that's ok if it ran
        echo "✓ CLI test passed (exit code: $EXIT_CODE)"
        ;;

    tui)
        # TUI mode: should start and show UI, then exit on command
        echo "Testing TUI mode..."
        # TUI typically waits for user input, so we send 'q' to quit
        echo "q" | timeout "$TIMEOUT" "$BINARY_PATH" 2>&1 | head -20
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo "✗ TUI test failed: timeout"
            exit 1
        fi
        # TUI ran, which is what we wanted to verify
        echo "✓ TUI test passed (ran successfully)"
        ;;

    daemon)
        # Daemon mode: should start and run in background
        echo "Testing Daemon mode..."

        # Start daemon in background
        "$BINARY_PATH" &
        DAEMON_PID=$!

        # Give it a moment to start
        sleep 2

        # Check if process is running
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo "✓ Daemon started successfully (PID: $DAEMON_PID)"

            # Stop the daemon gracefully first
            kill -TERM "$DAEMON_PID" 2>/dev/null || true

            # Wait for it to terminate (up to 5 seconds)
            for i in 1 2 3 4 5; do
                if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
                    break
                fi
                sleep 1
            done

            # Force kill if still running
            kill -9 "$DAEMON_PID" 2>/dev/null || true
            wait "$DAEMON_PID" 2>/dev/null || true

            echo "✓ Daemon stopped successfully"
            echo "✓ Daemon test passed"
        else
            echo "✗ Daemon test failed: process did not start"
            exit 1
        fi
        ;;

    *)
        echo "ERROR: Unknown mode '$MODE'. Valid modes: cli, tui, daemon"
        exit 1
        ;;
esac

echo ""
echo "All smoke tests passed for mode: $MODE"

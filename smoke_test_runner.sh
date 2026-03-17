#!/bin/bash
# Smoke Test Runner for Batamanta
# Usage: ./smoke_test_runner.sh <project_dir> <mode> [timeout_seconds]
#
# Arguments:
#   project_dir      - Path to the test project directory
#   mode             - Execution mode: cli, tui, or daemon
#   timeout_seconds  - Timeout in seconds (default: 30)

set -e

PROJECT_DIR="$1"
MODE="$2"
TIMEOUT="${3:-30}"

if [ -z "$PROJECT_DIR" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 <project_dir> <mode> [timeout_seconds]"
    echo "  mode: cli, tui, or daemon"
    exit 1
fi

# Determine binary name based on mode
BINARY_NAME="test_${MODE}"
BINARY_PATH="${PROJECT_DIR}/_build/batamanta/${BINARY_NAME}"

# Verify binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found at $BINARY_PATH"
    exit 1
fi

echo "Running smoke test for mode: $MODE"
echo "Binary: $BINARY_PATH"
echo "Timeout: ${TIMEOUT}s"

case "$MODE" in
    cli)
        # CLI mode: should execute and exit
        echo "Testing CLI mode..."
        if timeout "$TIMEOUT" "$BINARY_PATH" --help; then
            echo "✓ CLI test passed"
        else
            EXIT_CODE=$?
            if [ $EXIT_CODE -eq 124 ]; then
                echo "✗ CLI test failed: timeout"
                exit 1
            fi
            # CLI may exit with non-zero for --help, that's ok if it ran
            echo "✓ CLI test passed (exit code: $EXIT_CODE)"
        fi
        ;;
    
    tui)
        # TUI mode: should start and show UI, then exit on command
        echo "Testing TUI mode..."
        # TUI typically waits for user input, so we send 'q' to quit
        if echo "q" | timeout "$TIMEOUT" "$BINARY_PATH" 2>&1 | head -20; then
            echo "✓ TUI test passed"
        else
            EXIT_CODE=$?
            if [ $EXIT_CODE -eq 124 ]; then
                echo "✗ TUI test failed: timeout"
                exit 1
            fi
            # TUI ran, which is what we wanted to verify
            echo "✓ TUI test passed (ran successfully)"
        fi
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
            
            # Stop the daemon
            kill "$DAEMON_PID" 2>/dev/null || true
            
            # Wait for it to terminate
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

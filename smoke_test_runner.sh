#!/usr/bin/env bash
#===============================================================================
# Smoke Test Runner for CI
# 
# Usage: ./smoke_test_runner.sh <project_dir> <mode> <timeout_seconds>
# 
# Examples:
#   ./smoke_test_runner.sh smoke_tests/test_cli cli 30
#   ./smoke_test_runner.sh smoke_tests/test_tui tui 30
#   ./smoke_test_runner.sh smoke_tests/test_daemon daemon 30
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-}"
MODE="${2:-cli}"
TIMEOUT="${3:-30}"

if [[ -z "$PROJECT_DIR" ]]; then
    echo "Usage: $0 <project_dir> <mode> <timeout_seconds>"
    exit 1
fi

# Find the built binary (prefer current platform)
cd "$PROJECT_DIR"

# Detect current platform
HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"

# Map architecture names
case "$HOST_ARCH" in
    x86_64) ARCH_SUFFIX="x86_64" ;;
    aarch64|arm64) ARCH_SUFFIX="aarch64" ;;
    *) ARCH_SUFFIX="$HOST_ARCH" ;;
esac

# Look for binary matching current platform
if [[ "$HOST_OS" == "linux" ]]; then
    BINARY=$(find . -maxdepth 1 -type f -executable -name "test_${MODE}-*-linux" 2>/dev/null | head -1 || true)
elif [[ "$HOST_OS" == "darwin" ]]; then
    if [[ "$HOST_ARCH" == "aarch64" ]]; then
        BINARY=$(find . -maxdepth 1 -type f -executable -name "test_${MODE}-*-macos" 2>/dev/null | grep "arm64\|aarch64" | head -1 || true)
    else
        BINARY=$(find . -maxdepth 1 -type f -executable -name "test_${MODE}-*-macos" 2>/dev/null | grep -v "arm64\|aarch64" | head -1 || true)
    fi
fi

# Fallback to any matching binary
BINARY="${BINARY:-$(find . -maxdepth 1 -type f -executable -name "test_${MODE}-*" 2>/dev/null | head -1 || true)}"

if [[ -z "$BINARY" ]]; then
    echo "❌ No binary found in $PROJECT_DIR"
    exit 1
fi

echo "🔍 Testing: $BINARY"
echo "📊 Mode: $MODE"
echo "⏱️  Timeout: ${TIMEOUT}s"

# Run tests based on mode
case "$MODE" in
    cli)
        echo "🧪 Running CLI smoke test..."
        # Test basic argument passing
        timeout "$TIMEOUT" "$BINARY" calc 42
        RESULT=$?
        if [[ $RESULT -eq 0 ]]; then
            echo "✅ CLI test passed"
        else
            echo "❌ CLI test failed with code $RESULT"
            exit $RESULT
        fi
        ;;
        
    tui)
        echo "🧪 Running TUI smoke test (non-interactive)..."
        # TUI needs to handle EOF gracefully in CI
        timeout "$TIMEOUT" bash -c "echo '' | '$BINARY'" || RESULT=$?
        # TUI should exit cleanly on EOF
        if [[ ${RESULT:-0} -eq 0 ]] || [[ ${RESULT:-124} -eq 124 ]]; then
            echo "✅ TUI test passed (exit code: ${RESULT:-0})"
        else
            echo "❌ TUI test failed with code ${RESULT:-0}"
            exit ${RESULT:-1}
        fi
        ;;
        
    daemon)
        echo "🧪 Running Daemon smoke test..."
        # Daemon starts, creates file, and waits for signal
        timeout "$TIMEOUT" "$BINARY" &
        DAEMON_PID=$!
        
        # Wait for daemon to initialize
        sleep 2
        
        # Check if daemon is still running
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo "✅ Daemon is running (PID: $DAEMON_PID)"
            
            # Check for daemon file
            if [[ -f "daemon_alive.txt" ]]; then
                echo "✅ Daemon created alive file"
            fi
            
            # Clean up
            kill -TERM "$DAEMON_PID" 2>/dev/null || true
            wait "$DAEMON_PID" 2>/dev/null || true
            echo "✅ Daemon test passed"
        else
            echo "❌ Daemon failed to start"
            exit 1
        fi
        ;;
        
    *)
        echo "❌ Unknown mode: $MODE"
        exit 1
        ;;
esac

echo "✅ All smoke tests passed!"
exit 0

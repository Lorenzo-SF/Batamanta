#!/usr/bin/env bash
#===============================================================================
# Smoke Test Runner for CI
# 
# Usage: ./smoke_test_runner.sh <project_dir> <mode> <timeout_seconds> [format]
# 
# Modes:
#   cli     - Command-line interface application
#   tui     - Terminal user interface application
#   daemon  - Background service application
#   escript - Standalone escript (no release, just escript.build)
# 
# Formats:
#   release - Release build (default)
#   escript - Escript build
# 
# Examples:
#   ./smoke_test_runner.sh smoke_tests/test_cli cli 30
#   ./smoke_test_runner.sh smoke_tests/test_tui tui 30
#   ./smoke_test_runner.sh smoke_tests/test_daemon daemon 30
#   ./smoke_test_runner.sh smoke_tests/test_escript escript 30
#===============================================================================

set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-}"
MODE="${2:-cli}"
TIMEOUT="${3:-30}"
FORMAT="${4:-release}"

if [[ -z "$PROJECT_DIR" ]]; then
    echo "Usage: $0 <project_dir> <mode> <timeout_seconds> [format]"
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

# For escript mode, handle specially since it doesn't follow naming convention
if [[ "$MODE" == "escript" ]]; then
    if [[ -x "./test_escript" ]]; then
        BINARY="./test_escript"
    else
        echo "❌ No escript binary found in $PROJECT_DIR"
        exit 1
    fi
else
    # Look for binary matching current platform (.run files)
    # First try with mode suffix (e.g., test_*-cli-*.run)
    if [[ "$HOST_OS" == "linux" ]]; then
        BINARY=$(find . -maxdepth 1 -type f -perm /111 -name "*-${MODE}-*-linux.run" 2>/dev/null | head -1 || true)
    elif [[ "$HOST_OS" == "darwin" ]]; then
        if [[ "$HOST_ARCH" == "aarch64" ]]; then
            BINARY=$(find . -maxdepth 1 -type f -perm /111 -name "*-${MODE}-*-macos.run" 2>/dev/null | grep "arm64\|aarch64" | head -1 || true)
        else
            BINARY=$(find . -maxdepth 1 -type f -perm /111 -name "*-${MODE}-*-macos.run" 2>/dev/null | grep -v "arm64\|aarch64" | head -1 || true)
        fi
    fi

    # Fallback to any .run file matching the format (release/escript)
    if [[ "$FORMAT" == "release" ]]; then
        BINARY="${BINARY:-$(find . -maxdepth 1 -type f -perm /111 -name "*-linux.run" 2>/dev/null | head -1 || true)}"
        BINARY="${BINARY:-$(find . -maxdepth 1 -type f -perm /111 -name "*-macos.run" 2>/dev/null | head -1 || true)}"
    elif [[ "$FORMAT" == "escript" ]]; then
        # Escript mode has different naming; handled separately above
        :
    fi

    # If still not found, try without .run extension (legacy)
    BINARY="${BINARY:-$(find . -maxdepth 1 -type f -perm /111 -name "*-${MODE}-*" ! -name "*.run" 2>/dev/null | head -1 || true)}"

    # Final fallback: any plain executable file (no extension) that
    # isn't this script or a known extension. Earlier perms like `-perm
    # /111` fail on some `find` implementations when the binary is
    # missing the group-execute bit (e.g. macOS smoke where `mix
    # batamanta` produces `app-version-arch-os` with no `.run` suffix
    # and chmod 0755 but platform `find` may not match `-perm /111`).
    # Use `-type f` + skipping known noise extensions + size>0 as a
    # robust last resort.
    if [[ -z "$BINARY" ]]; then
        BINARY=$(find . -maxdepth 1 -type f \
            \( ! -name "*.sh" -a ! -name "*.run" -a ! -name "*.exs" \
               -a ! -name "*.ex"   -a ! -name "*.beam" \
               -a ! -name "*.app"  -a ! -name "*.appup" \
               -a ! -name "*.boot" -a ! -name "mix.lock" \
               -a ! -name "mix.exs" -a ! -name "build" \) \
            ! -size 0 \
            2>/dev/null | head -1 || true)
        # Make sure it's at least readable and probably executable.
        # Some `find` builds don't honor `-perm /111` when the only
        # `+x` bit set is `o+x`. We chmod defensively.
        if [[ -n "$BINARY" ]] && [[ ! -x "$BINARY" ]]; then
            chmod +x "$BINARY" 2>/dev/null || true
        fi
    fi
fi

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
        # Two flavours of "daemon" mode coexist in this repo:
        #
        #   * Legacy `smoke_tests/test_daemon` — uses `execution_mode:
        #     :daemon`, starts a single long-running BEAM as `myapp
        #     --daemon`, and creates a `daemon_alive.txt` sentinel
        #     file. The wrapper forks the BEAM once and waits.
        #
        #   * New `smoke_tests/test_beam_daemon` — uses
        #     `batamanta: [daemon: [enabled: true]]`. The wrapper keeps
        #     a BEAM-supervised Unix-socket daemon alive across short
        #     CLI invocations; the smoke test is multi-call and uses
        #     `test_beam_daemon_runner.sh` to exercise the warm path.
        #
        # Branch on PROJECT_DIR so the new runner is used automatically
        # when CI maps `release-daemon` to test_beam_daemon.
        if [[ "$(basename "$PROJECT_DIR")" == "test_beam_daemon" ]]; then
            # Resolve relative PROJECT_DIR against SCRIPT_DIR (where this
            # script lives) rather than CWD — earlier we'd cd into the
            # project dir before reaching this branch, and `$PROJECT_DIR/..`
            # then resolved against `$CWD/smoke_tests/test_beam_daemon`,
            # producing a doubly-nested path that did not exist and
            # crashed the daemon smoke with 'No such file or directory'.
            abs_project_dir="$(cd "$SCRIPT_DIR/$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")"
            beam_runner="$abs_project_dir/../test_beam_daemon_runner.sh"
            if [[ ! -x "$beam_runner" ]]; then
                # Allow repo-relative path (CI runs from repo root).
                beam_runner="$SCRIPT_DIR/smoke_tests/test_beam_daemon_runner.sh"
            fi
            echo "🧪 Running BEAM-daemon smoke (test_beam_daemon)..."
            exec "$beam_runner" "${TIMEOUT:-15}"
        fi

        echo "🧪 Running legacy Daemon smoke test..."
        # Legacy path: daemon starts, creates file, and waits for signal.
        # The wrapper process exits, but the BEAM daemon continues.
        rm -f daemon_alive.txt daemon_heartbeat.txt 2>/dev/null || true
        timeout "$TIMEOUT" "$BINARY" &

        # Wait for daemon to initialize
        sleep 2

        # Check for daemon file (indicates daemon is running)
        if [[ -f "daemon_alive.txt" ]]; then
            echo "✅ Daemon is running (created daemon_alive.txt)"
            cat daemon_alive.txt

            # Find and kill the daemon process
            DAEMON_PIDS=$(pgrep -f "beam.smp.*$(basename "$BINARY")" 2>/dev/null || true)
            if [[ -n "$DAEMON_PIDS" ]]; then
                echo "✅ Found daemon process(es): $DAEMON_PIDS"
                for pid in $DAEMON_PIDS; do
                    kill -TERM "$pid" 2>/dev/null || true
                done
                sleep 1
            fi
            
            echo "✅ Daemon test passed"
        else
            echo "❌ Daemon failed to start (no daemon_alive.txt)"
            exit 1
        fi
        ;;
        
    escript)
        echo "🧪 Running Escript smoke test..."
        
        # BINARY already set in the detection phase above
        # Test 1: Basic execution with no args
        echo "📋 Test 1: Basic execution..."
        timeout "$TIMEOUT" "$BINARY" > /dev/null 2>&1
        RESULT=$?
        if [[ $RESULT -ne 0 ]]; then
            echo "❌ Escript basic test failed with code $RESULT"
            exit $RESULT
        fi
        echo "✅ Basic execution passed"
        
        # Test 2: Help output
        echo "📋 Test 2: Help output..."
        timeout "$TIMEOUT" "$BINARY" --help > /dev/null 2>&1
        RESULT=$?
        if [[ $RESULT -ne 0 ]]; then
            echo "❌ Escript help test failed with code $RESULT"
            exit $RESULT
        fi
        echo "✅ Help output passed"
        
        # Test 3: Version output
        echo "📋 Test 3: Version output..."
        timeout "$TIMEOUT" "$BINARY" --version > /dev/null 2>&1
        RESULT=$?
        if [[ $RESULT -ne 0 ]]; then
            echo "❌ Escript version test failed with code $RESULT"
            exit $RESULT
        fi
        echo "✅ Version output passed"
        
        # Test 4: Command with arguments
        echo "📋 Test 4: Command execution..."
        timeout "$TIMEOUT" "$BINARY" info > /dev/null 2>&1
        RESULT=$?
        if [[ $RESULT -ne 0 ]]; then
            echo "❌ Escript command test failed with code $RESULT"
            exit $RESULT
        fi
        echo "✅ Command execution passed"
        
        # Test 5: Calculator functionality
        echo "📋 Test 5: Calculator test..."
        timeout "$TIMEOUT" "$BINARY" calc "5 + 3" > /dev/null 2>&1
        RESULT=$?
        if [[ $RESULT -ne 0 ]]; then
            echo "❌ Escript calculator test failed with code $RESULT"
            exit $RESULT
        fi
        echo "✅ Calculator test passed"
        
        # Test 6: Verify output contains expected strings
        echo "📋 Test 6: Output verification..."
        OUTPUT=$(timeout "$TIMEOUT" "$BINARY" info 2>&1)
        if echo "$OUTPUT" | grep -q "BATAMANTA ESCRIPT SMOKE TEST"; then
            echo "✅ Output verification passed"
        else
            echo "❌ Output verification failed - expected banner not found"
            exit 1
        fi
        
        echo "✅ Escript test passed"
        ;;
        
    *)
        echo "❌ Unknown mode: $MODE"
        exit 1
        ;;
esac

echo "✅ All smoke tests passed!"
exit 0

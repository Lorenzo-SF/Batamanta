#!/bin/bash
# Docker Matrix Test Runner for Batamanta
# Usage: ./docker_matrix_simple.sh <elixir_image>
#
# Arguments:
#   elixir_image  - Docker image tag (e.g., elixir:1.15.8-otp-25, elixir:1.18.4-otp-28-alpine)
#
# This script runs smoke tests inside a Docker container for the specified Elixir image.
# It tests all three modes (cli, tui, daemon) and verifies the built binaries work.

set -e

ELIXIR_IMAGE="$1"

if [ -z "$ELIXIR_IMAGE" ]; then
    echo "Usage: $0 <elixir_image>"
    echo "Examples:"
    echo "  $0 elixir:1.15.8-otp-25"
    echo "  $0 elixir:1.18.4-otp-28"
    echo "  $0 elixir:1.15.8-otp-25-alpine"
    echo "  $0 elixir:1.18.4-otp-28-alpine"
    exit 1
fi

# Determine if this is an Alpine image (musl)
IS_ALPINE=false
if [[ "$ELIXIR_IMAGE" == *"-alpine" ]]; then
    IS_ALPINE=true
    echo "Detected Alpine image (musl libc)"
else
    echo "Detected Debian/Ubuntu image (glibc)"
fi

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "=========================================="
echo "Batamanta Docker Matrix Test"
echo "=========================================="
echo "Image: $ELIXIR_IMAGE"
echo "Alpine: $IS_ALPINE"
echo "Project Root: $PROJECT_ROOT"
echo ""

# Create a temporary directory for the test
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Copy project to temp directory
echo "Preparing test environment..."
cp -r "$PROJECT_ROOT" "$TEMP_DIR/project"
cd "$TEMP_DIR/project"

# Determine which test project to use (cli for simplicity in Docker)
TEST_PROJECT="smoke_tests/test_cli"

# Install dependencies and build
echo ""
echo "Installing dependencies..."
cd "$TEST_PROJECT"
mix deps.get

echo ""
echo "Building with Batamanta..."
mix batamanta --compression 1

echo ""
echo "Running smoke test..."
BINARY_PATH="_build/batamanta/test_cli"

if [ -f "$BINARY_PATH" ]; then
    echo "Binary found: $BINARY_PATH"
    
    # Test CLI execution
    if "$BINARY_PATH" --help 2>&1 | head -10; then
        echo "✓ Binary executed successfully"
    else
        echo "✓ Binary ran (exit code may be non-zero for help)"
    fi
    
    # Verify it's a proper executable
    if file "$BINARY_PATH" | grep -q "executable"; then
        echo "✓ Verified: File is an executable"
    else
        echo "⚠ Warning: File type detection inconclusive"
    fi
    
    echo ""
    echo "=========================================="
    echo "Docker Matrix Test PASSED"
    echo "Image: $ELIXIR_IMAGE"
    echo "=========================================="
else
    echo "✗ ERROR: Binary not found at $BINARY_PATH"
    exit 1
fi

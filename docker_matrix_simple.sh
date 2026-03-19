#!/usr/bin/env bash
#===============================================================================
# Docker Matrix Test Script
# 
# Runs smoke tests inside Docker containers with various Elixir/OTP combinations.
# 
# Usage: ./docker_matrix_simple.sh <image>
# 
# Examples:
#   ./docker_matrix_simple.sh elixir:1.18.4-otp-28
#   ./docker_matrix_simple.sh elixir:1.18.4-otp-28-alpine
#   ./docker_matrix_simple.sh hexpm/elixir:1.15.8-otp-25
#===============================================================================

set -euo pipefail

IMAGE="${1:-elixir:1.18.4-otp-28}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
CONTAINER_NAME="batamanta-test-$(date +%s)-$$"

echo "🐳 Docker Matrix Test"
echo "📦 Image: $IMAGE"

# Determine if Alpine (musl) or Debian (glibc)
if [[ "$IMAGE" == *"alpine"* ]]; then
    LIBTYPE="musl"
    RUST_TARGET="x86_64-unknown-linux-musl"
else
    LIBTYPE="glibc"
    RUST_TARGET="x86_64-unknown-linux-gnu"
fi

echo "🔧 Lib type: $LIBTYPE"
echo "🎯 Rust target: $RUST_TARGET"

# Build the Docker image with inline Dockerfile
DOCKERFILE=$(cat <<'DOCKERFILE_EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    build-essential \
    zstd

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Add Rust target
RUN . /root/.cargo/env && rustup target add ${RUST_TARGET}

# Copy project
WORKDIR /project
COPY . .

# Build the test project
WORKDIR /project/smoke_tests/test_cli
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix batamanta --compression 1

# Test the binary
WORKDIR /project/smoke_tests/test_cli
CMD ["sh", "-c", "echo '' | ./test_cli-*-x86_64-linux calc 42"]
DOCKERFILE_EOF
)

# Build the Docker image
docker build \
    -t "batamanta-test:${LIBTYPE}" \
    --build-arg "BASE_IMAGE=${IMAGE}" \
    --build-arg "RUST_TARGET=${RUST_TARGET}" \
    -f - "$PROJECT_ROOT" <<<"$DOCKERFILE"

echo "🚀 Running container test..."
docker run --rm --name "$CONTAINER_NAME" "batamanta-test:${LIBTYPE}" || {
    echo "❌ Docker test failed"
    docker logs "$CONTAINER_NAME" 2>&1 || true
    exit 1
}

echo "✅ Docker matrix test passed!"
exit 0

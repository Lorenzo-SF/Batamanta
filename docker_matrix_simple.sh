#!/usr/bin/env bash
#===============================================================================
# Docker Matrix Test Script
# 
# Runs smoke tests inside Docker containers with various Elixir/OTP combinations.
# 
# Usage: ./docker_matrix_simple.sh <image>
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
    IS_ALPINE=true
else
    LIBTYPE="glibc"
    IS_ALPINE=false
fi

echo "🔧 Lib type: $LIBTYPE"

# Build the Docker image based on image type
if $IS_ALPINE; then
    # Alpine: Use rustup to get proper musl target support
    docker build \
        -t "batamanta-test:${LIBTYPE}" \
        --build-arg "BASE_IMAGE=${IMAGE}" \
        -f - "$PROJECT_ROOT" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Install system dependencies
RUN apk add --no-cache curl build-base zstd

# Install Rust with musl target
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# Add musl target for Alpine
RUN rustup target add x86_64-unknown-linux-musl

# Copy project
WORKDIR /project
COPY . .

# Build the test project
WORKDIR /project/smoke_tests/test_cli
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix batamanta --compression 1

# Test the binary
CMD ["sh", "-c", "echo '' | ./test_cli-*-x86_64-linux calc 42"]
EOF
else
    # Debian: Install rustup with glibc target
    docker build \
        -t "batamanta-test:${LIBTYPE}" \
        --build-arg "BASE_IMAGE=${IMAGE}" \
        -f - "$PROJECT_ROOT" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential zstd

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

# Add glibc target
RUN rustup target add x86_64-unknown-linux-gnu

# Copy project
WORKDIR /project
COPY . .

# Build the test project
WORKDIR /project/smoke_tests/test_cli
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix batamanta --compression 1

# Test the binary
CMD ["sh", "-c", "echo '' | ./test_cli-*-x86_64-linux calc 42"]
EOF
fi

echo "🚀 Running container test..."
docker run --rm --name "$CONTAINER_NAME" "batamanta-test:${LIBTYPE}" || {
    echo "❌ Docker test failed"
    docker logs "$CONTAINER_NAME" 2>&1 || true
    exit 1
}

echo "✅ Docker matrix test passed!"
exit 0

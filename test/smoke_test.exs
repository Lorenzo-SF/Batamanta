defmodule SmokeTest do
  use ExUnit.Case

  @moduledoc """
  Smoke tests are executed in CI (see .github/workflows/ci.yml).

  The CI job creates real Elixir projects at runtime, packages them with
  batamanta, and verifies the resulting binaries work correctly.

  This includes testing:
  - All execution modes (cli, tui, daemon)
  - Multiple target platforms (linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64)
  - Cross-compilation

  To run smoke tests locally, you would need:
  - Rust toolchain with cross-compilation targets
  - musl-tools (Linux)
  - Full Elixir/Mix environment

  See .github/workflows/ci.yml for the complete smoke test implementation.
  """
end

defmodule SmokeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Local smoke tests — quick sanity checks that don't need a Docker
  matrix, a Rust toolchain, or musl-tools.

  The full smoke matrix (real `mix batamanta` runs against
  linux/macos x windows, CLI/TUI/Daemon, escript/release) is
  executed in CI under `.github/workflows/ci.yml`. That matrix
  needs:

    * Docker (or native macOS/Windows runners)
    * Rust toolchain with cross-compilation targets installed
    * `musl-tools` (Linux) for the musl builds
    * A full Elixir/Mix environment

  and is not viable to run on every developer's machine. What this
  file gives you is a fast, no-deps sanity check that the wiring is
  in place: the modules are loaded, the mix task is registered, and
  the public API surface is what the rest of the suite (and the
  Rust dispenser) depends on.

  To run the local smoke: `mix test test/smoke_test.exs`
  To run the full matrix: see `.github/workflows/ci.yml`.
  """

  alias Batamanta.{Compression, Target}
  alias Batamanta.ERTS.{Fetcher, LibcDetector}

  describe "module wiring" do
    test "Compression layer is loaded with the three default backends" do
      assert Code.ensure_loaded?(Compression)
      assert Code.ensure_loaded?(Compression.Zstd)
      assert Code.ensure_loaded?(Compression.Gzip)
      assert Code.ensure_loaded?(Compression.None)
    end

    test "Target + ERTS modules are loaded" do
      assert Code.ensure_loaded?(Target)
      assert Code.ensure_loaded?(Fetcher)
      assert Code.ensure_loaded?(LibcDetector)
    end
  end

  describe "Compression API" do
    test "magic_bytes/1 returns the documented prefixes" do
      # Zstandard: RFC 8478 §3.1.1, little-endian frame magic
      assert Compression.magic_bytes(:zstd) == <<0x28, 0xB5, 0x2F, 0xFD>>
      # Gzip: RFC 1952 §2
      assert Compression.magic_bytes(:gzip) == <<0x1F, 0x8B>>
      # No compression: empty magic
      assert Compression.magic_bytes(:none) == <<>>
    end

    test "ext/1 returns the canonical file extension" do
      assert Compression.ext(:zstd) == ".zst"
      assert Compression.ext(:gzip) == ".gz"
      assert Compression.ext(:none) == ""
    end

    test "resolve_format(:auto) picks the first available backend" do
      # `:auto` resolves to whatever the system has. We don't pin a
      # specific backend here because the CI box and the developer's
      # laptop may differ — we just assert that *some* backend came
      # back, and that it matches the available?/0 predicate.
      assert {:ok, backend} = Compression.resolve_format(:auto)
      assert backend in [:zstd, :gzip, :none]
      assert Compression.module_for(backend).available?()
    end
  end

  describe "Target matrix" do
    test "valid_targets/0 returns the documented six targets" do
      targets = Target.valid_targets()
      assert is_list(targets)
      # 4 Linux + 1 darwin + 1 windows = 6
      assert length(targets) == 6
      assert :ubuntu_22_04_x86_64 in targets
      assert :alpine_3_19_x86_64 in targets
      assert :macos_12_arm64 in targets
      assert :windows_x86_64 in targets
    end

    test "every supported target maps to a manifest_key" do
      for target <- Target.valid_targets() do
        key = Target.manifest_key(target)
        assert is_binary(key) and key != "",
               "target #{inspect(target)} has empty manifest_key"
      end
    end
  end

  describe "Mix task" do
    test "mix batamanta task is registered" do
      # The mix task gets registered when Mix.Tasks.Batamanta is
      # loaded. If the file is loaded, the task is in Mix.Task.
      assert Code.ensure_loaded?(Mix.Tasks.Batamanta)
      # `mix batamanta` is the public entrypoint; it accepts a
      # verb (build/clean/help) and a list of project options.
      assert function_exported?(Mix.Tasks.Batamanta, :run, 1)
    end
  end
end

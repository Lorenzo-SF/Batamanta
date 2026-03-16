defmodule Batamanta.TargetTest do
  use ExUnit.Case, async: true

  alias Batamanta.Target

  test "resolve/1 returns ok for valid erts targets" do
    assert {:ok, info} = Target.resolve(:ubuntu_22_04_x86_64)
    assert info.os == "linux"
    assert info.arch == "x86_64"
    assert info.libc == "gnu"
    assert info.rust_target == "x86_64-unknown-linux-gnu"

    assert {:ok, info} = Target.resolve(:alpine_3_19_x86_64)
    assert info.libc == "musl"
    assert info.rust_target == "x86_64-unknown-linux-musl"

    assert {:ok, info} = Target.resolve(:macos_12_x86_64)
    assert info.os == "macos"
    assert info.rust_target == "x86_64-apple-darwin"

    assert {:ok, info} = Target.resolve(:macos_12_arm64)
    assert info.rust_target == "aarch64-apple-darwin"
  end

  test "resolve/1 returns error on invalid target" do
    assert {:error, msg} = Target.resolve(:unknown_random_target)
    assert String.contains?(msg, "Unknown ERTS target")
  end

  test "erts_target_to_rust/1 converts to correct Rust target" do
    assert Target.erts_target_to_rust(:ubuntu_22_04_x86_64) == "x86_64-unknown-linux-gnu"
    assert Target.erts_target_to_rust(:alpine_3_19_x86_64) == "x86_64-unknown-linux-musl"
    assert Target.erts_target_to_rust(:macos_12_x86_64) == "x86_64-apple-darwin"
    assert Target.erts_target_to_rust(:macos_12_arm64) == "aarch64-apple-darwin"
    assert Target.erts_target_to_rust(:windows_x86_64) == "x86_64-pc-windows-msvc"
  end

  test "erts_target_to_display/1 returns human-readable format" do
    assert Target.erts_target_to_display(:ubuntu_22_04_x86_64) == "Linux x86_64 (glibc)"
    assert Target.erts_target_to_display(:alpine_3_19_x86_64) == "Linux x86_64 (musl)"
    assert Target.erts_target_to_display(:macos_12_x86_64) == "macOS x86_64"
    assert Target.erts_target_to_display(:macos_12_arm64) == "macOS aarch64 (Apple Silicon)"
  end

  test "get_target_info/1 returns map for valid targets" do
    info = Target.get_target_info(:ubuntu_22_04_x86_64)
    assert is_map(info)
    assert info.os == "linux"
    assert info.arch == "x86_64"

    assert Target.get_target_info(:invalid_target) == nil
  end

  test "valid_targets/0 returns list of all supported targets" do
    targets = Target.valid_targets()
    assert is_list(targets)
    refute targets == []
    assert :ubuntu_22_04_x86_64 in targets
    assert :alpine_3_19_x86_64 in targets
    assert :macos_12_x86_64 in targets
    assert :macos_12_arm64 in targets
  end

  test "detect_host/1 returns current host target" do
    {:ok, target} = Target.detect_host()
    assert is_atom(target)
    assert target in Target.valid_targets()
  end

  test "resolve_auto/2 with :auto detects host" do
    {:ok, target} = Target.resolve_auto(:auto, %{})
    assert is_atom(target)
    assert target in Target.valid_targets()
  end

  test "resolve_auto/2 with explicit target returns it" do
    {:ok, target} = Target.resolve_auto(:alpine_3_19_x86_64, %{})
    assert target == :alpine_3_19_x86_64
  end

  test "resolve_auto/2 with overrides builds correct target" do
    {:ok, target} =
      Target.resolve_auto(:auto, %{force_os: "linux", force_arch: "x86_64", force_libc: "musl"})

    assert target == :alpine_3_19_x86_64

    {:ok, target} = Target.resolve_auto(:auto, %{force_os: "linux", force_arch: "x86_64"})
    assert target == :ubuntu_22_04_x86_64
  end

  test "from_legacy/2 converts old style to new erts_target" do
    assert Target.from_legacy("linux", "x86_64") == :ubuntu_22_04_x86_64
    assert Target.from_legacy("macos", "aarch64") == :macos_12_arm64
    assert Target.from_legacy(:auto, :auto) in Target.valid_targets()
  end
end

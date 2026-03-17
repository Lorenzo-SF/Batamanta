defmodule Batamanta.TargetExtendedTest do
  use ExUnit.Case, async: true

  alias Batamanta.Target

  describe "detect_libc/0" do
    test "returns libc type for current system" do
      result = Target.detect_libc()
      # En macOS debería devolver :unknown
      # En Linux debería devolver :gnu o :musl
      assert result in [:gnu, :musl, :unknown]
    end
  end

  describe "validate_libc!/1" do
    test "returns :ok for valid target" do
      # validate_libc! usa detect_libc() internamente
      # En macOS detect_libc() devuelve :unknown
      # Skip if ldd is not available (e.g., in minimal CI environments)
      if System.find_executable("ldd") != nil or File.exists?("/lib/ld-linux-x86-64.so.2") do
        assert :ok = Target.validate_libc!(:ubuntu_22_04_x86_64)
      end
    end

    test "shows warning for mismatched targets" do
      # Este test verifica que no falle
      # Skip if ldd is not available (e.g., in minimal CI environments)
      if System.find_executable("ldd") != nil or File.exists?("/lib/ld-linux-x86-64.so.2") do
        assert :ok = Target.validate_libc!(:alpine_3_19_x86_64)
      end
    end
  end

  describe "from_legacy/2" do
    test "converts linux x86_64 to ubuntu target" do
      assert Target.from_legacy("linux", "x86_64") == :ubuntu_22_04_x86_64
    end

    test "converts linux aarch64 to ubuntu arm64 target" do
      assert Target.from_legacy("linux", "aarch64") == :ubuntu_22_04_arm64
    end

    test "converts macos x86_64 to macos target" do
      assert Target.from_legacy("macos", "x86_64") == :macos_12_x86_64
    end

    test "converts macos aarch64 to macos arm64 target" do
      assert Target.from_legacy("macos", "aarch64") == :macos_12_arm64
    end

    test "converts windows x86_64 to windows target" do
      assert Target.from_legacy("windows", "x86_64") == :windows_x86_64
    end

    test "uses auto detection when both are :auto" do
      result = Target.from_legacy(:auto, :auto)
      assert result in Target.valid_targets()
    end

    test "defaults to ubuntu for unknown combinations" do
      assert Target.from_legacy("unknown", "unknown") == :ubuntu_22_04_x86_64
    end
  end

  describe "erts_target_to_rust/1" do
    test "converts ubuntu x86_64 to rust target" do
      assert Target.erts_target_to_rust(:ubuntu_22_04_x86_64) == "x86_64-unknown-linux-gnu"
    end

    test "converts ubuntu arm64 to rust target" do
      assert Target.erts_target_to_rust(:ubuntu_22_04_arm64) == "aarch64-unknown-linux-gnu"
    end

    test "converts alpine x86_64 to rust target" do
      assert Target.erts_target_to_rust(:alpine_3_19_x86_64) == "x86_64-unknown-linux-musl"
    end

    test "converts alpine arm64 to rust target" do
      assert Target.erts_target_to_rust(:alpine_3_19_arm64) == "aarch64-unknown-linux-musl"
    end

    test "converts macos x86_64 to rust target" do
      assert Target.erts_target_to_rust(:macos_12_x86_64) == "x86_64-apple-darwin"
    end

    test "converts macos arm64 to rust target" do
      assert Target.erts_target_to_rust(:macos_12_arm64) == "aarch64-apple-darwin"
    end

    test "converts windows to rust target" do
      assert Target.erts_target_to_rust(:windows_x86_64) == "x86_64-pc-windows-msvc"
    end
  end

  describe "erts_target_to_display/1" do
    test "returns human readable name for ubuntu" do
      assert Target.erts_target_to_display(:ubuntu_22_04_x86_64) == "Linux x86_64 (glibc)"
    end

    test "returns human readable name for alpine" do
      assert Target.erts_target_to_display(:alpine_3_19_x86_64) == "Linux x86_64 (musl)"
    end

    test "returns human readable name for macos" do
      assert Target.erts_target_to_display(:macos_12_x86_64) == "macOS x86_64"
    end

    test "returns human readable name for macos arm64" do
      assert Target.erts_target_to_display(:macos_12_arm64) == "macOS aarch64 (Apple Silicon)"
    end

    test "returns human readable name for windows" do
      assert Target.erts_target_to_display(:windows_x86_64) == "Windows x86_64"
    end
  end

  describe "erts_target_to_binary_suffix/1" do
    test "returns arch-os suffix for ubuntu" do
      assert Target.erts_target_to_binary_suffix(:ubuntu_22_04_x86_64) == "x86_64-linux"
    end

    test "returns arch-os suffix for alpine" do
      assert Target.erts_target_to_binary_suffix(:alpine_3_19_x86_64) == "x86_64-linux"
    end

    test "returns arch-os suffix for macos" do
      assert Target.erts_target_to_binary_suffix(:macos_12_x86_64) == "x86_64-macos"
    end

    test "returns arch-os suffix for windows" do
      assert Target.erts_target_to_binary_suffix(:windows_x86_64) == "x86_64-windows"
    end
  end
end

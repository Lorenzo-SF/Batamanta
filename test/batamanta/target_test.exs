defmodule Batamanta.TargetTest do
  use ExUnit.Case, async: true

  alias Batamanta.Target

  describe "erts_target_to_rust/1" do
    test "converts ubuntu_22_04_x86_64 to rust target" do
      assert Target.erts_target_to_rust(:ubuntu_22_04_x86_64) == "x86_64-unknown-linux-gnu"
    end

    test "converts ubuntu_22_04_arm64 to rust target" do
      assert Target.erts_target_to_rust(:ubuntu_22_04_arm64) == "aarch64-unknown-linux-gnu"
    end

    test "converts alpine_3_19_x86_64 to rust target" do
      assert Target.erts_target_to_rust(:alpine_3_19_x86_64) == "x86_64-unknown-linux-musl"
    end

    test "converts alpine_3_19_arm64 to rust target" do
      assert Target.erts_target_to_rust(:alpine_3_19_arm64) == "aarch64-unknown-linux-musl"
    end

    test "converts macos_12_x86_64 to rust target" do
      assert Target.erts_target_to_rust(:macos_12_x86_64) == "x86_64-apple-darwin"
    end

    test "converts macos_12_arm64 to rust target" do
      assert Target.erts_target_to_rust(:macos_12_arm64) == "aarch64-apple-darwin"
    end

    test "converts windows_x86_64 to rust target" do
      assert Target.erts_target_to_rust(:windows_x86_64) == "x86_64-pc-windows-msvc"
    end

    test "raises for unknown target" do
      assert_raise RuntimeError, ~r/Invalid ERTS target/, fn ->
        Target.erts_target_to_rust(:unknown)
      end
    end
  end

  describe "get_target_info/1" do
    test "returns info for ubuntu_22_04_x86_64" do
      info = Target.get_target_info(:ubuntu_22_04_x86_64)
      assert info.os == "linux"
      assert info.arch == "x86_64"
      assert info.libc == "gnu"
    end

    test "returns info for alpine_3_19_x86_64" do
      info = Target.get_target_info(:alpine_3_19_x86_64)
      assert info.os == "linux"
      assert info.arch == "x86_64"
      assert info.libc == "musl"
    end

    test "returns info for macos_12_arm64" do
      info = Target.get_target_info(:macos_12_arm64)
      assert info.os == "macos"
      assert info.arch == "aarch64"
      assert is_nil(info.libc)
    end

    test "returns nil for unknown target" do
      assert Target.get_target_info(:unknown_target) == nil
    end
  end

  describe "valid_targets/0" do
    test "returns list of all supported targets" do
      targets = Target.valid_targets()
      assert is_list(targets)
      assert length(targets) >= 7
      assert :ubuntu_22_04_x86_64 in targets
      assert :alpine_3_19_x86_64 in targets
      assert :macos_12_arm64 in targets
      assert :windows_x86_64 in targets
    end
  end
end

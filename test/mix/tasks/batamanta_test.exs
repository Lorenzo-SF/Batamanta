defmodule Mix.Tasks.BatamantaTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Batamanta

  describe "validate_toolchain!/0" do
    test "passes when cargo is available" do
      try do
        Batamanta.validate_toolchain!()
        assert true
      rescue
        Mix.Error ->
          flunk("cargo should be available for tests")
      end
    end

    test "raises when cargo is not found" do
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        assert_raise Mix.Error, ~r/Rust \(cargo\) not found/, fn ->
          Batamanta.validate_toolchain!()
        end
      after
        if original_path,
          do: System.put_env("PATH", original_path),
          else: System.delete_env("PATH")
      end
    end
  end

  describe "parse_options/1" do
    test "parses erts-target option" do
      opts = Batamanta.parse_options(["--erts-target", "alpine_3_19_x86_64"])
      assert opts[:erts_target] == "alpine_3_19_x86_64"
    end

    test "parses otp-version option" do
      opts = Batamanta.parse_options(["--otp-version", "28.1"])
      assert opts[:otp_version] == "28.1"
    end

    test "parses force-os option" do
      opts = Batamanta.parse_options(["--force-os", "linux"])
      assert opts[:force_os] == "linux"
    end

    test "parses force-arch option" do
      opts = Batamanta.parse_options(["--force-arch", "aarch64"])
      assert opts[:force_arch] == "aarch64"
    end

    test "parses force-libc option" do
      opts = Batamanta.parse_options(["--force-libc", "musl"])
      assert opts[:force_libc] == "musl"
    end

    test "parses compression option" do
      opts = Batamanta.parse_options(["--compression", "9"])
      assert opts[:compression] == 9
    end

    test "parses multiple options" do
      opts =
        Batamanta.parse_options([
          "--erts-target",
          "alpine_3_19_x86_64",
          "--otp-version",
          "28.1",
          "--compression",
          "5"
        ])

      assert opts[:erts_target] == "alpine_3_19_x86_64"
      assert opts[:otp_version] == "28.1"
      assert opts[:compression] == 5
    end
  end

  describe "resolve_erts_target/2" do
    test "returns erts_target from opts" do
      result = Batamanta.resolve_erts_target([erts_target: :alpine_3_19_x86_64], [])
      assert result == :alpine_3_19_x86_64
    end

    test "returns erts_target from bata_config" do
      result = Batamanta.resolve_erts_target([], erts_target: :ubuntu_22_04_x86_64)
      assert result == :ubuntu_22_04_x86_64
    end

    test "returns :auto when not specified" do
      result = Batamanta.resolve_erts_target([], [])
      assert result == :auto
    end

    test "opts take precedence over bata_config" do
      result =
        Batamanta.resolve_erts_target(
          [erts_target: :alpine_3_19_x86_64],
          erts_target: :ubuntu_22_04_x86_64
        )

      assert result == :alpine_3_19_x86_64
    end
  end

  describe "build_override_config/2" do
    test "builds config from opts" do
      result =
        Batamanta.build_override_config(
          [force_os: "linux", force_arch: "x86_64", force_libc: "musl"],
          []
        )

      assert result.force_os == "linux"
      assert result.force_arch == "x86_64"
      assert result.force_libc == "musl"
    end

    test "builds config from bata_config when opts empty" do
      result =
        Batamanta.build_override_config(
          [],
          force_os: "macos",
          force_arch: "aarch64"
        )

      assert result.force_os == "macos"
      assert result.force_arch == "aarch64"
    end

    test "opts take precedence over bata_config" do
      result =
        Batamanta.build_override_config(
          [force_os: "linux"],
          force_os: "macos"
        )

      assert result.force_os == "linux"
    end
  end

  describe "resolve_otp_version/2" do
    test "returns otp_version from bata_config with :explicit mode" do
      result = Batamanta.resolve_otp_version([], otp_version: "26.0")
      assert result == {"26.0", :explicit}
    end

    test "returns otp_version from opts with :explicit mode" do
      result = Batamanta.resolve_otp_version([otp_version: "27.0"], [])
      assert result == {"27.0", :explicit}
    end

    test "opts take precedence over bata_config" do
      result =
        Batamanta.resolve_otp_version(
          [otp_version: "27.0"],
          otp_version: "26.0"
        )

      # Priority: opts > bata_config > system
      assert result == {"27.0", :explicit}
    end

    test "returns system OTP with :auto mode when not specified" do
      result = Batamanta.resolve_otp_version([], [])
      expected = :erlang.system_info(:otp_release) |> to_string()
      assert result == {expected, :auto}
    end
  end
end

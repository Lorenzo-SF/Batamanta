defmodule Batamanta.ValidatorTest do
  use ExUnit.Case, async: true

  alias Batamanta.Validator

  describe "validate!/1" do
    test "accepts valid linux cli configuration" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts valid linux tui configuration" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "aarch64",
                 mode: :tui,
                 otp_version: "27",
                 elixir_version: "1.17"
               )
    end

    test "accepts valid linux daemon configuration" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :daemon,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts valid macos configuration" do
      assert :ok =
               Validator.validate!(
                 os: "macos",
                 arch: "aarch64",
                 mode: :cli,
                 otp_version: "27",
                 elixir_version: "1.17"
               )
    end

    test "accepts minimum OTP version (25)" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "25",
                 elixir_version: "1.15"
               )
    end

    test "accepts minimum Elixir version (1.15.0)" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "25",
                 elixir_version: "1.15.0"
               )
    end

    test "accepts auto OS" do
      assert :ok =
               Validator.validate!(
                 os: :auto,
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts auto architecture" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: :auto,
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts :auto for both OS and arch" do
      assert :ok =
               Validator.validate!(
                 os: :auto,
                 arch: :auto,
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end
  end

  describe "validate!/1 - OS validation" do
    test "rejects unsupported OS" do
      assert_raise ArgumentError, ~r/Unsupported OS/, fn ->
        Validator.validate!(
          os: "freebsd",
          arch: "x86_64",
          mode: :cli,
          otp_version: "28",
          elixir_version: "1.18"
        )
      end
    end

    test "accepts linux" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts macos" do
      assert :ok =
               Validator.validate!(
                 os: "macos",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts windows" do
      assert :ok =
               Validator.validate!(
                 os: "windows",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end
  end

  describe "validate!/1 - Architecture validation" do
    test "rejects unsupported architecture" do
      assert_raise ArgumentError, ~r/Unsupported architecture/, fn ->
        Validator.validate!(
          os: "linux",
          arch: "i386",
          mode: :cli,
          otp_version: "28",
          elixir_version: "1.18"
        )
      end
    end

    test "accepts x86_64" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts aarch64" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "aarch64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end
  end

  describe "validate!/1 - Mode validation" do
    test "accepts :cli mode" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts :tui mode on Linux" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :tui,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts :tui mode on macOS" do
      assert :ok =
               Validator.validate!(
                 os: "macos",
                 arch: "x86_64",
                 mode: :tui,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts :daemon mode on Linux" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :daemon,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts :daemon mode on macOS" do
      assert :ok =
               Validator.validate!(
                 os: "macos",
                 arch: "x86_64",
                 mode: :daemon,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "rejects unsupported mode" do
      assert_raise ArgumentError, ~r/Unsupported execution mode/, fn ->
        Validator.validate!(
          os: "linux",
          arch: "x86_64",
          mode: :invalid,
          otp_version: "28",
          elixir_version: "1.18"
        )
      end
    end
  end

  describe "validate!/1 - OTP version validation" do
    test "rejects OTP below 25" do
      assert_raise ArgumentError, ~r/OTP version must be >= 25/, fn ->
        Validator.validate!(
          os: "linux",
          arch: "x86_64",
          mode: :cli,
          otp_version: "24",
          elixir_version: "1.18"
        )
      end
    end

    test "accepts OTP 25" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "25",
                 elixir_version: "1.15"
               )
    end

    test "accepts OTP 26" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "26",
                 elixir_version: "1.16"
               )
    end

    test "accepts OTP 27" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "27",
                 elixir_version: "1.17"
               )
    end

    test "accepts OTP 28" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts OTP 28.1" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28.1",
                 elixir_version: "1.18"
               )
    end

    test "rejects invalid OTP version format" do
      assert_raise ArgumentError, ~r/Invalid OTP version/, fn ->
        Validator.validate!(
          os: "linux",
          arch: "x86_64",
          mode: :cli,
          otp_version: "abc",
          elixir_version: "1.18"
        )
      end
    end
  end

  describe "validate!/1 - Elixir version validation" do
    test "rejects Elixir below 1.15" do
      assert_raise ArgumentError, ~r/Elixir version must be >= 1.15.0/, fn ->
        Validator.validate!(
          os: "linux",
          arch: "x86_64",
          mode: :cli,
          otp_version: "28",
          elixir_version: "1.14"
        )
      end
    end

    test "accepts Elixir 1.15" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "25",
                 elixir_version: "1.15"
               )
    end

    test "accepts Elixir 1.18" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end

    test "accepts Elixir 1.19.5" do
      assert :ok =
               Validator.validate!(
                 os: "linux",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.19.5"
               )
    end
  end

  describe "validate!/1 - OS/Mode combinations" do
    test "rejects Windows with TUI mode" do
      assert_raise ArgumentError, ~r/:tui.*not supported on Windows/, fn ->
        Validator.validate!(
          os: "windows",
          arch: "x86_64",
          mode: :tui,
          otp_version: "28",
          elixir_version: "1.18"
        )
      end
    end

    test "rejects Windows with Daemon mode" do
      assert_raise ArgumentError, ~r/:daemon.*not supported on Windows/, fn ->
        Validator.validate!(
          os: "windows",
          arch: "x86_64",
          mode: :daemon,
          otp_version: "28",
          elixir_version: "1.18"
        )
      end
    end

    test "accepts Windows with CLI mode" do
      assert :ok =
               Validator.validate!(
                 os: "windows",
                 arch: "x86_64",
                 mode: :cli,
                 otp_version: "28",
                 elixir_version: "1.18"
               )
    end
  end

  describe "valid_combination?/1" do
    test "returns true for valid linux cli" do
      assert Validator.valid_combination?(%{os: "linux", mode: :cli})
    end

    test "returns true for valid linux tui" do
      assert Validator.valid_combination?(%{os: "linux", mode: :tui})
    end

    test "returns true for valid linux daemon" do
      assert Validator.valid_combination?(%{os: "linux", mode: :daemon})
    end

    test "returns false for windows tui" do
      refute Validator.valid_combination?(%{os: "windows", mode: :tui})
    end

    test "returns false for windows daemon" do
      refute Validator.valid_combination?(%{os: "windows", mode: :daemon})
    end

    test "returns false for invalid map" do
      refute Validator.valid_combination?(%{foo: "bar"})
    end
  end

  describe "supported_combinations/0" do
    test "returns list" do
      combinations = Validator.supported_combinations()
      assert is_list(combinations)
    end

    test "returns non-empty list" do
      combinations = Validator.supported_combinations()
      assert combinations != []
    end
  end

  describe "compatibility_matrix/0" do
    test "returns string" do
      matrix = Validator.compatibility_matrix()
      assert is_binary(matrix)
      assert String.contains?(matrix, "BATAMANTA COMPATIBILITY MATRIX")
      assert String.contains?(matrix, "Linux")
      assert String.contains?(matrix, "macOS")
    end
  end
end

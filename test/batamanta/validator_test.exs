defmodule Batamanta.ValidatorTest do
  use ExUnit.Case, async: true

  alias Batamanta.Validator

  describe "validate!/1" do
    test "returns :ok for valid Linux configuration" do
      assert :ok = Validator.validate!(os: "linux", arch: "x86_64", mode: :cli)
    end

    test "returns :ok for valid macOS configuration" do
      assert :ok = Validator.validate!(os: "macos", arch: "aarch64", mode: :daemon)
    end

    test "raises on unsupported OS" do
      assert_raise ArgumentError, ~r/Unsupported OS/, fn ->
        Validator.validate!(os: "freebsd", arch: "x86_64", mode: :cli)
      end
    end

    test "raises on unsupported architecture" do
      assert_raise ArgumentError, ~r/Unsupported architecture/, fn ->
        Validator.validate!(os: "linux", arch: "riscv64", mode: :cli)
      end
    end

    test "raises on unsupported execution mode" do
      assert_raise ArgumentError, ~r/Unsupported execution mode/, fn ->
        Validator.validate!(os: "linux", arch: "x86_64", mode: :invalid)
      end
    end

    test "raises on Windows + TUI combination" do
      assert_raise ArgumentError, ~r/not supported on Windows/, fn ->
        Validator.validate!(os: "windows", arch: "x86_64", mode: :tui)
      end
    end

    test "raises on Windows + daemon combination" do
      assert_raise ArgumentError, ~r/not supported on Windows/, fn ->
        Validator.validate!(os: "windows", arch: "x86_64", mode: :daemon)
      end
    end

    test "allows Windows + CLI combination" do
      assert :ok = Validator.validate!(os: "windows", arch: "x86_64", mode: :cli)
    end

    test "accepts :auto for os and arch" do
      assert :ok = Validator.validate!(os: :auto, arch: :auto, mode: :cli)
    end

    test "works with partial configuration" do
      assert :ok = Validator.validate!(mode: :cli)
      assert :ok = Validator.validate!(os: "linux")
    end
  end

  describe "valid_combination?/1" do
    test "returns true for valid Linux combinations" do
      assert Validator.valid_combination?(%{os: "linux", arch: "x86_64", mode: :cli})
    end

    test "returns true for valid macOS combinations" do
      assert Validator.valid_combination?(%{os: "macos", arch: "aarch64", mode: :tui})
    end

    test "returns false for Windows + TUI" do
      refute Validator.valid_combination?(%{os: "windows", arch: "x86_64", mode: :tui})
    end

    test "returns false for Windows + daemon" do
      refute Validator.valid_combination?(%{os: "windows", arch: "x86_64", mode: :daemon})
    end

    test "returns true for Windows + CLI" do
      assert Validator.valid_combination?(%{os: "windows", arch: "x86_64", mode: :cli})
    end

    test "returns false for invalid input" do
      refute Validator.valid_combination?(nil)
      refute Validator.valid_combination?("invalid")
    end
  end

  describe "compatibility_matrix/0" do
    test "returns a string with matrix information" do
      matrix = Validator.compatibility_matrix()
      assert is_binary(matrix)
      assert String.contains?(matrix, "BATAMANTA COMPATIBILITY MATRIX")
      assert String.contains?(matrix, "OPERATING SYSTEMS")
      assert String.contains?(matrix, "EXECUTION MODES")
    end
  end
end

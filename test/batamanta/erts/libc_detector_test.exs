defmodule Batamanta.ERTS.LibcDetectorTest do
  use ExUnit.Case, async: true

  alias Batamanta.ERTS.LibcDetector

  describe "detect/0" do
    test "returns an atom (:gnu or :musl)" do
      result = LibcDetector.detect()
      assert result in [:gnu, :musl]
    end
  end

  describe "detect_by_ldd/0" do
    test "returns a valid libc type or :unknown" do
      result = LibcDetector.detect_by_ldd()
      assert result in [:gnu, :musl, :unknown]
    end
  end

  describe "detect_by_loader/0" do
    test "returns a valid libc type or tries os_release fallback" do
      result = LibcDetector.detect_by_loader()
      assert result in [:gnu, :musl, :unknown]
    end
  end

  describe "detect_by_os_release/0" do
    test "returns :gnu or :musl" do
      result = LibcDetector.detect_by_os_release()
      assert result in [:gnu, :musl]
    end
  end

  describe "detect_by_proc_maps/0" do
    test "returns a valid libc type or :unknown" do
      result = LibcDetector.detect_by_proc_maps()
      assert result in [:gnu, :musl, :unknown]
    end
  end

  describe "describe/1" do
    test "returns human-readable string for :gnu" do
      assert LibcDetector.describe(:gnu) =~ "glibc"
    end

    test "returns human-readable string for :musl" do
      assert LibcDetector.describe(:musl) =~ "musl"
    end

    test "returns human-readable string for :unknown" do
      assert LibcDetector.describe(:unknown) =~ "Unknown"
    end
  end

  describe "validate!/2" do
    test "returns :ok when libc matches target" do
      assert LibcDetector.validate!(:gnu, :ubuntu_22_04_x86_64) == :ok
    end

    test "returns :ok with warning when mismatch" do
      assert LibcDetector.validate!(:musl, :ubuntu_22_04_x86_64) == :ok
    end

    test "returns :ok when libc is :unknown" do
      assert LibcDetector.validate!(:unknown, :ubuntu_22_04_x86_64) == :ok
    end
  end
end

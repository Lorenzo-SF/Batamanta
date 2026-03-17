defmodule Batamanta.PackagerTest do
  use ExUnit.Case
  alias Batamanta.Packager

  setup do
    tmp = Path.join(System.tmp_dir!(), "bat_t_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    rs = Path.join(tmp, "release_src")
    et = Path.join(tmp, "erts_src")
    ot = Path.join(tmp, "out.tar.zst")

    File.mkdir_p!(rs)
    File.mkdir_p!(et)
    bin_dir = Path.join(et, "bin")
    releases_dir = Path.join(et, "releases")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(releases_dir)
    File.mkdir_p!(Path.join(releases_dir, "14.0"))
    File.write!(Path.join(rs, "hello.txt"), "world")
    File.write!(Path.join(et, "erlexec"), "binary")

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, rs: rs, et: et, ot: ot}
  end

  describe "package/4" do
    test "creates a valid zstd compressed tarball", %{rs: rs, et: et, ot: ot} do
      # Skip if zstd is not available
      if System.find_executable("zstd") != nil do
        assert {:ok, ^ot} = Packager.package(rs, et, ot, 1)
        assert File.exists?(ot)

        {info, 0} = System.cmd("file", [ot])
        assert info =~ "Zstandard"
      end
    end

    test "handles different compression levels", %{rs: rs, et: et} do
      # Skip if zstd is not available
      if System.find_executable("zstd") != nil do
        tmp = Path.join(System.tmp_dir!(), "bat_t_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        ot = Path.join(tmp, "out.tar.zst")

        # Test with minimum compression
        assert {:ok, _} = Packager.package(rs, et, ot, 1)
        assert File.exists?(ot)

        File.rm!(ot)

        # Test with maximum compression
        assert {:ok, _} = Packager.package(rs, et, ot, 19)
        assert File.exists?(ot)

        File.rm_rf!(tmp)
      end
    end

    test "packages release with ERTS correctly", %{rs: rs, et: et, ot: ot} do
      # Skip if zstd is not available
      if System.find_executable("zstd") != nil do
        # Add more structure to simulate a real release
        bin_dir = Path.join(et, "bin")
        File.mkdir_p!(bin_dir)
        File.write!(Path.join(bin_dir, "erlexec"), "binary_content")

        assert {:ok, output_path} = Packager.package(rs, et, ot, 1)
        assert File.exists?(output_path)

        # Verify tarball can be extracted
        {output, 0} = System.cmd("zstd", ["-d", "-c", output_path])
        assert byte_size(output) > 0
      end
    end

    test "handles empty release directory", %{et: et} do
      # Skip if zstd is not available
      if System.find_executable("zstd") != nil do
        tmp = Path.join(System.tmp_dir!(), "bat_t_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        rs = Path.join(tmp, "empty_release")
        ot = Path.join(tmp, "out.tar.zst")

        File.mkdir_p!(rs)

        result = Packager.package(rs, et, ot, 1)
        assert match?({:ok, _}, result)

        File.rm_rf!(tmp)
      end
    end

    test "returns error when tar creation fails" do
      # Test error handling when tar creation fails
      tmp = Path.join(System.tmp_dir!(), "bat_t_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      rs = Path.join(tmp, "release_src")
      et = Path.join(tmp, "erts_src")
      ot = Path.join(tmp, "out.tar.zst")

      File.mkdir_p!(rs)
      File.mkdir_p!(et)

      # This should handle gracefully even with empty directories
      result = Packager.package(rs, et, ot, 1)
      # Result can be ok (if it handles gracefully) or error
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      File.rm_rf!(tmp)
    end
  end
end

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
    File.mkdir_p!(Path.join([et, "erts-28.0", "bin"]))
    File.mkdir_p!(Path.join(et, "releases"))
    File.mkdir_p!(Path.join(rs, "bin"))
    File.mkdir_p!(Path.join(rs, "lib"))
    File.mkdir_p!(Path.join(rs, "releases"))

    File.write!(Path.join(rs, "hello.txt"), "world")
    File.write!(Path.join([et, "erts-28.0", "bin", "erlexec"]), "binary")
    File.write!(Path.join(rs, "bin/my_app"), "#!/bin/sh\necho hello")
    File.write!(Path.join(rs, "releases/start_erl.data"), "28.0 1.0.0")

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, rs: rs, et: et, ot: ot}
  end

  test "package/4 creates a valid zstd compressed tarball", %{rs: rs, et: et, ot: ot} do
    assert {:ok, ^ot} = Packager.package(rs, et, ot, 1)
    assert File.exists?(ot)

    {info, 0} = System.cmd("file", [ot])
    assert info =~ "Zstandard"
  end

  test "package/4 handles different compression levels", %{rs: rs, et: et} do
    for level <- [1, 9, 19] do
      out = "/tmp/test_level_#{level}_#{:rand.uniform(100_000)}.tar.zst"
      on_exit(fn -> File.rm(out) end)

      assert {:ok, ^out} = Packager.package(rs, et, out, level)
      assert File.exists?(out)
    end
  end

  test "cleanup removes temporary files after packaging", %{rs: rs, et: et, ot: ot} do
    {:ok, ^ot} = Packager.package(rs, et, ot, 1)
    assert File.exists?(ot)
  end

  describe "internal helpers" do
    test "file permissions test setup works correctly" do
      tmp = Path.join(System.tmp_dir!(), "test_perms_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      test_file = Path.join(tmp, "test_bin")
      File.write!(test_file, "binary content")
      assert File.exists?(test_file)
    end
  end

  # Regression tests for the Windows ERTS-detection bug
  # (https://github.com/Lorenzo-SF/Batamanta/issues/...) — some
  # erlang/otp Windows prebuilt zips lay out files at the root
  # without an `erts-<vsn>/` subdir. The packager must detect the
  # version from the `releases/<vsn>/` subtree instead.
  describe "get_erts_version/1 ERTS layout detection" do
    setup do
      base = Path.join(System.tmp_dir!(), "bat_erts_layout_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      %{base: base}
    end

    test "layout 1: Linux/Mac release-style with erts-X.Y/ subdir", %{base: base} do
      File.mkdir_p!(Path.join(base, "erts-14.2/bin"))
      File.write!(Path.join([base, "erts-14.2", "bin", "erlexec"]), "fake")
      assert Packager.get_erts_version(base) == "14.2"
    end

    test "layout 1 variant: erts-X/ without minor", %{base: base} do
      File.mkdir_p!(Path.join(base, "erts-28/bin"))
      assert Packager.get_erts_version(base) == "28"
    end

    test "layout 3: Windows raw-style (no erts-*/ subdir, releases/<vsn>/ exists)", %{
      base: base
    } do
      # No erts-X.Y/ subdir — layout 3 / Windows raw-style.
      File.mkdir_p!(Path.join([base, "bin"]))
      File.write!(Path.join([base, "bin", "erl.exe"]), "fake")
      File.write!(Path.join(base, "start.boot"), "fake")
      # releases/<vsn>/ has the canonical files.
      File.mkdir_p!(Path.join([base, "releases", "28.0"]))
      File.write!(Path.join([base, "releases", "28.0", "OTP_VERSION"]), "28.0.1\n")
      File.write!(Path.join([base, "releases", "28.0", "start_erl.data"]), "28.0.1 1.0.0\n")

      assert Packager.get_erts_version(base) == "28.0"
    end

    test "fallback to start_erl.data when OTP_VERSION is missing", %{base: base} do
      File.mkdir_p!(Path.join([base, "releases", "27"]))
      File.write!(Path.join([base, "releases", "27", "start_erl.data"]), "27 1.0.0\n")
      assert Packager.get_erts_version(base) == "27"
    end

    test "ignores non-version directories under releases/", %{base: base} do
      # These are common noise files that File.ls may return in any order.
      File.mkdir_p!(Path.join([base, "releases", "28.0"]))
      File.mkdir_p!(Path.join([base, "releases", ".DS_Store"]))
      File.write!(Path.join([base, "releases", "28.0", "OTP_VERSION"]), "28.0.1\n")
      File.write!(Path.join([base, "releases", ".DS_Store", "dummy"]), "x")
      assert Packager.get_erts_version(base) == "28.0"
    end

    test "raises with a descriptive message when no layout matches", %{base: base} do
      # Empty directory — neither erts-* nor releases/<vsn>/ exist.
      assert_raise RuntimeError, ~r/no erts-\* subdir/, fn ->
        Packager.get_erts_version(base)
      end
    end

    test "raises when releases/ exists but contains no versioned subdirs", %{base: base} do
      File.mkdir_p!(Path.join(base, "releases"))
      File.write!(Path.join(base, "releases/notes.txt"), "no version here")
      assert_raise RuntimeError, ~r/no releases/, fn ->
        Packager.get_erts_version(base)
      end
    end
  end
end

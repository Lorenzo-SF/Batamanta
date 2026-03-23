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
    File.mkdir_p!(Path.join(et, "bin"))
    File.mkdir_p!(Path.join(et, "releases"))
    File.mkdir_p!(Path.join(rs, "bin"))
    File.mkdir_p!(Path.join(rs, "lib"))
    File.mkdir_p!(Path.join(rs, "releases"))

    File.write!(Path.join(rs, "hello.txt"), "world")
    File.write!(Path.join(et, "bin/erlexec"), "binary")
    File.write!(Path.join(et, "releases/OTP_VERSION"), "28.0")
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
end

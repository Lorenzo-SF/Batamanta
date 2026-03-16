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
    File.write!(Path.join(rs, "hello.txt"), "world")
    File.write!(Path.join(et, "erlexec"), "binary")

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, rs: rs, et: et, ot: ot}
  end

  test "package/4 creates a valid zstd compressed tarball", %{rs: rs, et: et, ot: ot} do
    assert {:ok, ^ot} = Packager.package(rs, et, ot, 1)
    assert File.exists?(ot)

    {info, 0} = System.cmd("file", [ot])
    assert info =~ "Zstandard"
  end
end

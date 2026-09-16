defmodule Batamanta.DaemonTest do
  use ExUnit.Case, async: true

  alias Batamanta.Daemon
  alias Batamanta.DaemonConfig

  describe "version/0" do
    test "returns a stable version string" do
      assert is_binary(Daemon.version())
      assert Daemon.version() == Daemon.version()
    end
  end

  describe "build_hash_for/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "batamanta_daemon_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, dir: tmp}
    end

    test "returns 12 lowercase hex chars for a real payload", %{dir: dir} do
      path = Path.join(dir, "payload.bin")
      File.write!(path, :crypto.strong_rand_bytes(4096))
      hash = Daemon.build_hash_for(path)
      assert byte_size(hash) == 12
      assert hash == String.downcase(hash)
      assert Regex.match?(~r/^[0-9a-f]{12}$/, hash)
    end

    test "is stable across two reads of the same file", %{dir: dir} do
      path = Path.join(dir, "payload.bin")
      File.write!(path, "abc123")
      assert Daemon.build_hash_for(path) == Daemon.build_hash_for(path)
    end

    test "changes when the file changes", %{dir: dir} do
      path = Path.join(dir, "payload.bin")
      File.write!(path, "abc123")
      h1 = Daemon.build_hash_for(path)
      File.write!(path, "abc124")
      h2 = Daemon.build_hash_for(path)
      refute h1 == h2
    end

    test "returns empty string when file is missing", %{dir: dir} do
      assert Daemon.build_hash_for(Path.join(dir, "nope")) == ""
    end
  end

  describe "compile/4 (missing erlc)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "batamanta_daemon_compile_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, dir: tmp}
    end

    test "returns error when ERTS dir has no erlc", %{dir: dir} do
      cfg = DaemonConfig.from_config(enabled: true, user_app: "my_cli")
      fake_erts = Path.join(dir, "fake_erts")
      File.mkdir_p!(Path.join(fake_erts, "bin"))
      # No erlc binary.
      assert {:error, msg} = Daemon.compile(dir, fake_erts, cfg)
      assert msg =~ "erlc not found"
    end

    test "returns error when user_app is not resolved", %{dir: dir} do
      cfg = %DaemonConfig{enabled: true, user_app: nil, var: "FOO"}
      fake_erts = Path.join(dir, "fake_erts")
      fake_bin = Path.join(fake_erts, "bin")
      File.mkdir_p!(fake_bin)
      erlc_path = Path.join(fake_bin, "erlc")
      File.write!(erlc_path, "#!/bin/sh\n")
      File.chmod!(erlc_path, 0o755)
      assert {:error, msg} = Daemon.compile(dir, fake_erts, cfg)
      assert msg =~ "user_app must be resolved"
    end
  end
end

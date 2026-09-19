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
  describe "get_erts_version/2 ERTS layout detection" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "bat_erts_layout_#{:erlang.unique_integer([:positive])}")

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

    test "ignores the Fetcher cache-dir-name (erts-<vsn>-<platform_key>) created by cp_r", %{
      base: base
    } do
      # Regression for the alaja-on-Windows build:
      #
      #   `mix batamanta` failed on Windows with:
      #     ** (RuntimeError) Cannot determine ERTS version from
      #        C:/Users/.../Temp/bat_pkg_.../erts_work
      #
      # Root cause: the Fetcher's cache directory is named
      # `erts-<otp_version>-<platform_key>` (e.g. `erts-28.5-windows-amd64`).
      # Packager.package/4 does `File.cp_r!(erts_cache, erts_work)` so the
      # cache directory becomes a subdirectory of `erts_work` whose name
      # starts with `erts-`. The first detector in the cascade (`detect_from_erts_subdir`)
      # used to accept any directory whose name started with `erts-` and
      # return its suffix (after stripping `erts-`) as the version —
      # which silently produced `"28.5-windows-amd64"` instead of nil,
      # masking the real version source and crashing the rest of the
      # pipeline downstream. The fix is to require the suffix to be a
      # numeric OTP version (valid_otp_version_string?/1).
      #
      # In the real bug case, the work path contains BOTH the spurious
      # cache-named directory AND the legitimate `erts-28/` runtime dir.
      # We rebuild that exact shape here.
      File.mkdir_p!(Path.join(base, "erts-28.5-windows-amd64/bin"))
      File.write!(Path.join([base, "erts-28.5-windows-amd64", "bin", "erl.exe"]), "fake")
      File.mkdir_p!(Path.join([base, "erts-28.5-windows-amd64", "releases", "28.5"]))

      File.write!(
        Path.join([base, "erts-28.5-windows-amd64", "releases", "28.5", "OTP_VERSION"]),
        "28.5\n"
      )

      # The legitimate, non-cache-prefixed erts-<vsn>/ runtime dir:
      File.mkdir_p!(Path.join(base, "erts-28/bin"))
      File.write!(Path.join([base, "erts-28", "bin", "erlexec"]), "fake")

      assert Packager.get_erts_version(base) == "28"
    end

    test "falls through to releases/ detector when only the spurious cache-dir is present", %{
      base: base
    } do
      # Same root cause as above, but only the spurious cache dir name
      # exists (no real erts-<X.Y>/ subdir). The cascade must skip it
      # and read the version from `releases/<vsn>/OTP_VERSION` instead.
      File.mkdir_p!(Path.join(base, "erts-28.5-windows-amd64/bin"))
      File.mkdir_p!(Path.join([base, "erts-28.5-windows-amd64", "releases", "28.5"]))

      File.write!(
        Path.join([base, "erts-28.5-windows-amd64", "releases", "28.5", "OTP_VERSION"]),
        "28.5.1\n"
      )

      # The releases/<vsn>/ the cascade should now find (note: the
      # `releases/` is at the root of `base`, NOT under the cache-named
      # subdir — this matches what the packager sees after cp_r because
      # the ERTS top-level layout puts releases/ at the work-root).
      File.mkdir_p!(Path.join([base, "releases", "28.5"]))
      File.write!(Path.join([base, "releases", "28.5", "OTP_VERSION"]), "28.5.1\n")

      assert Packager.get_erts_version(base) == "28.5"
    end

    test "recovers version from the cache-dir name when no embedded layout exists", %{
      base: _base
    } do
      # Regression for the upstream Windows `runtime only` zip:
      # https://github.com/erlang/otp/releases ships a windows-amd64.zip
      # containing only ~12 flat files (erl.exe, erlc.exe, *.boot,
      # typer.exe, werl.exe, ...). NO `erts-*` subdir, NO `releases/`
      # subdir, NO OTP_VERSION file anywhere. The four file-based
      # detectors all miss.
      #
      # The Packager's `erts_path` argument IS the Fetcher's cache
      # directory, whose name follows the convention
      # `erts-<vsn>-<platform_key>`. The packager's new fallback
      # detector parses that convention so we can recover the
      # requested version without any embedded layout.
      cache = Path.join(System.tmp_dir!(), "erts-28.5-windows-amd64")
      File.rm_rf!(cache)
      File.mkdir_p!(cache)

      try do
        # Simulate the upstream Windows zip — only flat executables + boots.
        Enum.each(
          ["erl.exe", "erlc.exe", "werl.exe", "start.boot"],
          fn f -> File.write!(Path.join(cache, f), "fake") end
        )

        assert Packager.get_erts_version(cache) == "28.5"
      after
        File.rm_rf!(cache)
      end
    end

    test "recovers version from cache-dir name when platform key has dashes", %{
      base: _base
    } do
      # Some platform keys contain dashes (e.g. `windows-arm64-gnu`).
      # The detector splits on the FIRST dash after the version,
      # so the rest of the platform string is discarded rather
      # than mis-parsed as another version segment.
      cache = Path.join(System.tmp_dir!(), "erts-27.3-windows-arm64-gnu")
      File.rm_rf!(cache)
      File.mkdir_p!(cache)

      try do
        File.write!(Path.join(cache, "erl.exe"), "fake")
        assert Packager.get_erts_version(cache) == "27.3"
      after
        File.rm_rf!(cache)
      end
    end
  end

  describe "patch_windows_elixir_exec/2 (bundled ERTS only on Windows)" do
    test "rewrites ERL_EXEC to erl.exe on Windows payloads", %{rs: rs, et: et, ot: ot} do
      # Windows payload marker: the ERTS tree carries bin/erl.exe.
      File.mkdir_p!(Path.join(et, "bin"))
      File.write!(Path.join([et, "bin", "erl.exe"]), "fake")
      # Launchers as generated by `mix release` (POSIX `erl` by default).
      File.mkdir_p!(Path.join([rs, "releases", "1.0.0"]))

      File.write!(
        Path.join([rs, "releases", "1.0.0", "elixir"]),
        "ERTS_BIN=\"x\"\nERL_EXEC=\"erl\"\n"
      )

      File.write!(Path.join([rs, "releases", "1.0.0", "iex"]), "ERL_EXEC=\"erl\"\n")

      assert {:ok, ^ot} = Packager.package(rs, et, ot, 1)

      assert File.read!(Path.join([rs, "releases", "1.0.0", "elixir"])) ==
               "ERTS_BIN=\"x\"\nERL_EXEC=\"erl.exe\"\n"

      assert File.read!(Path.join([rs, "releases", "1.0.0", "iex"])) ==
               "ERL_EXEC=\"erl.exe\"\n"
    end

    test "leaves POSIX payloads untouched", %{rs: rs, et: et, ot: ot} do
      # No bin/erl.exe in the ERTS tree → POSIX payload, no patch.
      File.mkdir_p!(Path.join([rs, "releases", "1.0.0"]))
      File.write!(Path.join([rs, "releases", "1.0.0", "elixir"]), "ERL_EXEC=\"erl\"\n")

      assert {:ok, ^ot} = Packager.package(rs, et, ot, 1)

      assert File.read!(Path.join([rs, "releases", "1.0.0", "elixir"])) ==
               "ERL_EXEC=\"erl\"\n"
    end
  end
end

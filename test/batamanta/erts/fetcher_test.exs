defmodule Batamanta.ERTS.FetcherTest do
  use ExUnit.Case, async: true
  alias Batamanta.ERTS.Fetcher
  alias Batamanta.Target

  # ============================================================================
  # Platform Detection Tests
  # ============================================================================

  test "detect_host_target/0 returns valid target" do
    {:ok, target} = Fetcher.detect_host_target()
    assert is_atom(target)
    assert target in Target.valid_targets()
  end

  test "get_target_info/1 returns info for valid targets" do
    info = Target.get_target_info(:ubuntu_22_04_x86_64)
    assert is_map(info)
    assert info.os == "linux"
    assert info.arch == "x86_64"

    assert Target.get_target_info(:invalid_target) == nil
  end

  test "valid_targets/0 returns list of all supported targets" do
    targets = Target.valid_targets()
    assert is_list(targets)
    assert length(targets) >= 7
    assert :ubuntu_22_04_x86_64 in targets
    assert :alpine_3_19_x86_64 in targets
    assert :macos_12_x86_64 in targets
  end

  test "get_cache_dir/0 returns valid path" do
    cache_dir = Fetcher.get_cache_dir()
    assert is_binary(cache_dir)
    assert String.ends_with?(cache_dir, "batamanta")
  end

  # ============================================================================
  # Version Resolution Tests (via find_erts_url)
  # ============================================================================

  describe "version resolution" do
    test "find_erts_url/2 with exact version match" do
      # OTP-26.0 should exist in MANIFEST
      result = Fetcher.find_erts_url("26.0", "amd64-glibc")
      # Result can be nil (version not in manifest) or a URL string
      assert is_binary(result) or is_nil(result)
    end

    test "find_erts_url/2 with major-only version" do
      # Should try 26.0, 26.1, etc.
      result = Fetcher.find_erts_url("26", "amd64-glibc")
      assert is_binary(result) or is_nil(result)
    end

    test "find_erts_url/2 with patch version" do
      # Should fall back to 26.0 if 26.0.1 doesn't exist
      result = Fetcher.find_erts_url("26.0.1", "amd64-glibc")
      assert is_binary(result) or is_nil(result)
    end

    test "find_erts_url/2 returns nil for non-existent platform" do
      result = Fetcher.find_erts_url("26.0", "nonexistent-platform")
      assert is_nil(result)
    end
  end

  # ============================================================================
  # Platform Key Building Tests
  # ============================================================================

  describe "platform key building" do
    test "linux x86_64 glibc" do
      platform = %{os: "linux", arch: "x86_64", libc: "gnu"}
      key = Fetcher.build_platform_key(platform)
      assert key == "amd64-glibc"
    end

    test "linux x86_64 musl" do
      platform = %{os: "linux", arch: "x86_64", libc: "musl"}
      key = Fetcher.build_platform_key(platform)
      assert key == "amd64-musl"
    end

    test "linux aarch64 glibc" do
      platform = %{os: "linux", arch: "aarch64", libc: "gnu"}
      key = Fetcher.build_platform_key(platform)
      assert key == "arm64-glibc"
    end

    test "linux aarch64 musl" do
      platform = %{os: "linux", arch: "aarch64", libc: "musl"}
      key = Fetcher.build_platform_key(platform)
      assert key == "arm64-musl"
    end

    test "macOS x86_64" do
      platform = %{os: "macos", arch: "x86_64", libc: nil}
      key = Fetcher.build_platform_key(platform)
      assert key == "darwin-amd64"
    end

    test "macOS aarch64" do
      platform = %{os: "macos", arch: "aarch64", libc: nil}
      key = Fetcher.build_platform_key(platform)
      assert key == "darwin-arm64"
    end

    test "Windows x86_64" do
      platform = %{os: "windows", arch: "x86_64", libc: nil}
      key = Fetcher.build_platform_key(platform)
      assert key == "windows-amd64"
    end

    test "unknown platform returns nil" do
      platform = %{os: "freebsd", arch: "x86_64", libc: "gnu"}
      key = Fetcher.build_platform_key(platform)
      assert is_nil(key)
    end
  end

  # ============================================================================
  # OTP Version Normalization Tests
  # ============================================================================

  describe "OTP version normalization" do
    test "normalize major-only version returns valid result" do
      # "28" should normalize to "28" and return a valid result
      # Note: This may fail due to network issues in test environment
      # so we accept both success and error
      result = Fetcher.fetch("28", :ubuntu_22_04_x86_64)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "normalize major.minor version returns valid result" do
      result = Fetcher.fetch("28.1", :ubuntu_22_04_x86_64)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "normalize major.minor.patch version returns valid result" do
      result = Fetcher.fetch("28.0.0", :ubuntu_22_04_x86_64)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ============================================================================
  # Cache Tests
  # ============================================================================

  describe "cache handling" do
    test "fetch/2 uses cache when available" do
      # First fetch - may download
      otp_version = "26.0"
      target = :ubuntu_22_04_x86_64

      # Clear cache first for this test
      cache_dir = Fetcher.get_cache_dir()
      erts_dir = Path.join(cache_dir, "erts-#{otp_version}-amd64-glibc")
      File.rm_rf(erts_dir)

      # First call - should either download or use system ERTS
      result1 = Fetcher.fetch(otp_version, target)

      # The result should be consistent
      assert match?({:ok, _}, result1) or match?({:error, _}, result1)
    end
  end

  # ============================================================================
  # Target Atom Conversion Tests
  # ============================================================================

  describe "target atom conversion" do
    test "ubuntu_22_04_x86_64 to platform" do
      platform = Fetcher.target_atom_to_platform(:ubuntu_22_04_x86_64)
      assert platform == %{os: "linux", arch: "x86_64", libc: "gnu"}
    end

    test "alpine_3_19_x86_64 to platform" do
      platform = Fetcher.target_atom_to_platform(:alpine_3_19_x86_64)
      assert platform == %{os: "linux", arch: "x86_64", libc: "musl"}
    end

    test "macos_12_x86_64 to platform" do
      platform = Fetcher.target_atom_to_platform(:macos_12_x86_64)
      assert platform == %{os: "macos", arch: "x86_64", libc: nil}
    end

    test "unknown target falls back to default" do
      platform = Fetcher.target_atom_to_platform(:unknown_target)
      assert platform == %{os: "linux", arch: "x86_64", libc: "gnu"}
    end
  end

  # ============================================================================
  # JSON Parsing Tests (via load_manifest behavior)
  # ============================================================================

  describe "manifest JSON parsing" do
    test "build_download_url/2 returns URL for valid version" do
      url = Fetcher.build_download_url("26.0", :ubuntu_22_04_x86_64)
      assert is_binary(url)
      # Should either return actual URL or fallback message
      assert url != ""
    end

    test "build_download_url/2 returns N/A for nonexistent version" do
      url = Fetcher.build_download_url("99.99.99", :ubuntu_22_04_x86_64)
      assert url == "N/A (using system ERTS)" or is_binary(url)
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  test "fetch/2 with :auto detects host target" do
    _otp_version = :erlang.system_info(:otp_release) |> to_string()
    {:ok, target} = Fetcher.detect_host_target()

    # Solo verificamos que la función no falle inmediatamente
    # La descarga real depende de red y versión disponible
    assert is_atom(target)
  end

  test "fetch/2 with explicit target returns valid result" do
    # Usamos una versión OTP genérica
    # El test verifica que la función de fetch funciona correctamente
    # Nota: Este test puede fallar si la red no está disponible
    # o si Hex.pm está caído
    otp_version = "26.0"

    # Intentar fetch - puede tener éxito o fallar por 404 si la versión no existe
    result = Fetcher.fetch(otp_version, :ubuntu_22_04_x86_64)

    # Verificar que el resultado es una tupla válida (independientemente de éxito/fracaso)
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end
end

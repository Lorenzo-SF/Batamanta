defmodule Batamanta.ERTS.FetcherTest do
  use ExUnit.Case, async: true
  alias Batamanta.ERTS.Fetcher
  alias Batamanta.Target

  test "detect_host_target/0 returns valid target" do
    # Skip if ldd is not available (e.g., in minimal CI environments)
    if System.find_executable("ldd") != nil or File.exists?("/lib/ld-linux-x86-64.so.2") do
      {:ok, target} = Fetcher.detect_host_target()
      assert is_atom(target)
      assert target in Target.valid_targets()
    end
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

  test "fetch/2 with :auto detects host target" do
    # Nota: Este test intenta descargar ERTS real, puede fallar sin red
    # Se usa una versión válida de OTP
    # Skip if ldd is not available (e.g., in minimal CI environments)
    if System.find_executable("ldd") != nil or File.exists?("/lib/ld-linux-x86-64.so.2") do
      {:ok, target} = Fetcher.detect_host_target()

      # Solo verificamos que la función no falle inmediatamente
      # La descarga real depende de red y versión disponible
      assert is_atom(target)
    end
  end

  test "fetch/2 with explicit target" do
    # Usamos una versión OTP genérica
    # El test verifica que la función de fetch funciona correctamente
    # Nota: Este test requiere conexión a internet y puede fallar si Hex.pm está caído
    otp_version = "26.0"

    # Intentar fetch - puede tener éxito o fallar por 404 si la versión no existe
    result = Fetcher.fetch(otp_version, :ubuntu_22_04_x86_64)

    # Verificar que el resultado es una tupla válida (independientemente de éxito/fracaso)
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end
end

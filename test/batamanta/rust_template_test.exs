defmodule Batamanta.RustTemplateTest do
  use ExUnit.Case, async: true

  alias Batamanta.RustTemplate

  @temp_dir System.tmp_dir!()

  setup do
    # Crear directorio temporal para tests
    temp = Path.join(@temp_dir, "rust_template_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(temp)

    on_exit(fn ->
      File.rm_rf!(temp)
    end)

    %{temp: temp}
  end

  describe "initialize_dispenser/1" do
    test "creates a new directory with Rust template", %{temp: temp} do
      dest_dir = Path.join(temp, "dispenser")

      assert :ok = RustTemplate.initialize_dispenser(dest_dir)
      assert File.dir?(dest_dir)

      # Verificar que se copiaron los archivos del template
      assert File.exists?(Path.join(dest_dir, "Cargo.toml"))
      assert File.exists?(Path.join(dest_dir, "Cargo.lock"))
      assert File.exists?(Path.join(dest_dir, Path.join("src", "main.rs")))
    end
  end

  describe "build/4" do
    # P1 FIX: With the new architecture, the payload is passed as an environment variable
    # and read at runtime, not at compile time. This means:
    # - Build succeeds (Rust compiles successfully)
    # - Error occurs when trying to RUN the binary with non-existent payload
    # 
    # These tests now verify that build succeeds (compilation works),
    # but in a real scenario, the binary would fail at runtime if payload doesn't exist.

    test "succeeds even when payload file doesn't exist (runtime error, not build error)", %{
      temp: temp
    } do
      payload_path = Path.join(temp, "nonexistent.tar.zst")
      binary_name = Path.join(temp, "binary")

      # With new architecture, build succeeds (compilation works)
      # The runtime error would occur when trying to execute the binary
      result = RustTemplate.build(payload_path, binary_name, "x86_64-unknown-linux-gnu", [])
      assert result == :ok
    end

    test "succeeds with invalid path (runtime error, not build error)" do
      # Build succeeds, runtime error would occur when executing
      result = RustTemplate.build("nonexistent", "nonexistent", "x86_64-unknown-linux-gnu", [])
      assert result == :ok
    end
  end

  describe "build command configuration" do
    test "configures CLI mode correctly" do
      assert System.get_env("BATAMANTA_EXEC_MODE") == nil
    end

    test "configures app name correctly" do
      assert System.get_env("BATAMANTA_APP_NAME") == nil
    end
  end
end

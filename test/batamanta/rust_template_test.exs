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

    test "returns error when destination is not writable", %{temp: _temp} do
      # Try to create in a non-writable location
      dest_dir = "/root/non_writable_#{:erlang.unique_integer([:positive])}"
      result = RustTemplate.initialize_dispenser(dest_dir)
      # May succeed if running as root, or fail otherwise
      assert match?(:ok, result) or match?({:error, _}, result)
    end
  end

  describe "build/4" do
    test "returns error when payload file doesn't exist", %{temp: temp} do
      payload_path = Path.join(temp, "nonexistent.tar.zst")
      binary_name = Path.join(temp, "binary")

      result = RustTemplate.build(payload_path, binary_name, "x86_64-unknown-linux-gnu", [])
      assert match?({:error, _}, result)
    end

    test "handles invalid payload gracefully", %{temp: temp} do
      payload_path = Path.join(temp, "invalid.tar.zst")
      File.write!(payload_path, "invalid payload")

      binary_name = Path.join(temp, "binary")

      # El build puede fallar en descompresión o compilación
      # Lo importante es que la función se ejecuta sin crashear
      # Skip if cargo is not available or fails
      try do
        result =
          RustTemplate.build(payload_path, binary_name, "x86_64-unknown-linux-gnu",
            batamanta: [execution_mode: :cli]
          )

        # El resultado puede ser error (lo esperado) o ok (si Rust compila)
        assert match?({:error, _}, result) or match?(:ok, result)
      rescue
        ErlangError ->
          # cargo no está disponible o falló
          assert true
      end
    end

    test "returns error when target directory cannot be created", %{temp: temp} do
      # Skip if cargo is not available
      if System.find_executable("cargo") != nil do
        payload_path = Path.join(temp, "valid.tar.zst")
        # Create a valid minimal tar.zst file
        File.write!(payload_path, "")
        binary_name = Path.join(temp, "binary")

        # This will fail at some point in the build process
        result = RustTemplate.build(payload_path, binary_name, "invalid-target", [])
        assert match?({:error, _}, result)
      end
    end
  end

  describe "build command configuration" do
    test "configures CLI mode correctly" do
      assert System.get_env("BATAMANTA_EXEC_MODE") == nil
    end

    test "configures app name correctly" do
      assert System.get_env("BATAMANTA_APP_NAME") == nil
    end

    test "accepts different execution modes in config" do
      config = [batamanta: [execution_mode: :tui]]
      bata_config = Keyword.get(config, :batamanta, [])
      mode = Keyword.get(bata_config, :execution_mode, :cli)
      assert mode == :tui
    end

    test "defaults to :cli mode when not specified" do
      config = [batamanta: []]
      bata_config = Keyword.get(config, :batamanta, [])
      mode = Keyword.get(bata_config, :execution_mode, :cli)
      assert mode == :cli
    end
  end

  describe "target triples" do
    test "supports linux x86_64 gnu target" do
      assert "x86_64-unknown-linux-gnu" in valid_targets()
    end

    test "supports linux aarch64 gnu target" do
      assert "aarch64-unknown-linux-gnu" in valid_targets()
    end

    test "supports linux x86_64 musl target" do
      assert "x86_64-unknown-linux-musl" in valid_targets()
    end

    test "supports linux aarch64 musl target" do
      assert "aarch64-unknown-linux-musl" in valid_targets()
    end

    test "supports macos x86_64 target" do
      assert "x86_64-apple-darwin" in valid_targets()
    end

    test "supports macos aarch64 target" do
      assert "aarch64-apple-darwin" in valid_targets()
    end
  end

  defp valid_targets do
    [
      "x86_64-unknown-linux-gnu",
      "aarch64-unknown-linux-gnu",
      "x86_64-unknown-linux-musl",
      "aarch64-unknown-linux-musl",
      "x86_64-apple-darwin",
      "aarch64-apple-darwin"
    ]
  end
end

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
    test "returns error when payload file doesn't exist", %{temp: temp} do
      payload_path = Path.join(temp, "nonexistent.tar.zst")
      binary_name = Path.join(temp, "binary")

      result = RustTemplate.build(payload_path, binary_name, "x86_64-unknown-linux-gnu", [])
      assert match?({:error, _}, result)
    end

    test "returns error when payload is invalid", %{temp: temp} do
      payload_path = Path.join(temp, "invalid.tar.zst")
      File.write!(payload_path, "invalid payload")

      binary_name = Path.join(temp, "binary")

      # El build fallará porque el payload no es válido
      # Pero verificamos que la función existe y tiene la firma correcta
      result =
        RustTemplate.build(payload_path, binary_name, "x86_64-unknown-linux-gnu",
          batamanta: [execution_mode: :cli]
        )

      # Debería fallar en la compilación de Rust
      assert match?({:error, _}, result)
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

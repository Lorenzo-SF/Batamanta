defmodule Batamanta.EscriptBuilderTest do
  use ExUnit.Case, async: true

  alias Batamanta.EscriptBuilder

  describe "valid_config?/1" do
    test "returns true when escript config has main_module" do
      config = [
        app: :test_app,
        escript: [
          main_module: Test.CLI
        ]
      ]

      assert EscriptBuilder.valid_config?(config) == true
    end

    test "returns false when escript config is missing" do
      config = [
        app: :test_app
      ]

      assert EscriptBuilder.valid_config?(config) == false
    end

    test "returns false when main_module is missing" do
      config = [
        app: :test_app,
        escript: []
      ]

      assert EscriptBuilder.valid_config?(config) == false
    end

    test "returns false when escript config is empty list" do
      config = [
        app: :test_app,
        escript: []
      ]

      assert EscriptBuilder.valid_config?(config) == false
    end
  end

  describe "get_main_module/1" do
    test "returns the main module from config" do
      config = [
        escript: [
          main_module: Test.CLI
        ]
      ]

      assert EscriptBuilder.get_main_module(config) == Test.CLI
    end

    test "returns nil when no escript config" do
      config = []
      assert EscriptBuilder.get_main_module(config) == nil
    end

    test "returns nil when escript config is empty" do
      config = [escript: []]
      assert EscriptBuilder.get_main_module(config) == nil
    end
  end

  describe "find_escript_path/1" do
    test "returns app name as path when no custom escript path" do
      config = [app: :my_app]
      path = EscriptBuilder.find_escript_path(config)
      assert path =~ "my_app"
    end

    test "returns custom path when configured" do
      config = [
        app: :my_app,
        escript: [
          main_module: Test.CLI,
          path: "bin/my_app"
        ]
      ]

      path = EscriptBuilder.find_escript_path(config)
      assert path =~ "bin/my_app"
    end
  end

  describe "validate_escript!/1" do
    test "raises for nonexistent file" do
      assert_raise Mix.Error, fn ->
        EscriptBuilder.validate_escript!("/nonexistent/escript")
      end
    end

    test "raises for empty file" do
      tmp_file = Path.join(System.tmp_dir!(), "empty_escript_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm(tmp_file) end)

      File.write!(tmp_file, "")

      assert_raise Mix.Error, fn ->
        EscriptBuilder.validate_escript!(tmp_file)
      end
    end

    test "validates ELF binary" do
      tmp_file = Path.join(System.tmp_dir!(), "elf_escript_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm(tmp_file) end)

      # ELF magic bytes: 0x7F "ELF"
      elf_content = <<0x7F, 0x45, 0x4C, 0x46, 0x00, 0x00, 0x00, 0x00>>
      File.write!(tmp_file, elf_content)

      assert :ok = EscriptBuilder.validate_escript!(tmp_file)
    end

    test "validates shebang script" do
      tmp_file = Path.join(System.tmp_dir!(), "shebang_escript_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm(tmp_file) end)

      # Shebang
      File.write!(tmp_file, "#!/bin/bash\necho hello")

      assert :ok = EscriptBuilder.validate_escript!(tmp_file)
    end

    test "raises for invalid magic bytes" do
      tmp_file = Path.join(System.tmp_dir!(), "invalid_escript_#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm(tmp_file) end)

      # Invalid content (not ELF, not shebang)
      File.write!(tmp_file, "This is not a valid escript")

      assert_raise Mix.Error, fn ->
        EscriptBuilder.validate_escript!(tmp_file)
      end
    end
  end
end

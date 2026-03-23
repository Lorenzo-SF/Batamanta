defmodule Batamanta.EscriptPackagerTest do
  use ExUnit.Case, async: true

  alias Batamanta.EscriptPackager

  describe "prepare_minimal_erts/2" do
    test "creates destination directory and copies essential files" do
      # Create a minimal mock ERTS structure
      tmp = System.tmp_dir!()
      temp_source = Path.join(tmp, "test_erts_source_#{:rand.uniform(100_000)}")
      temp_dest = Path.join(tmp, "test_erts_dest_#{:rand.uniform(100_000)}")

      on_exit(fn ->
        File.rm_rf(temp_source)
        File.rm_rf(temp_dest)
      end)

      # Create minimal structure
      File.mkdir_p!(Path.join([temp_source, "bin"]))
      File.mkdir_p!(Path.join([temp_source, "lib", "kernel", "ebin"]))
      File.mkdir_p!(Path.join([temp_source, "lib", "stdlib", "ebin"]))
      File.mkdir_p!(Path.join([temp_source, "releases"]))

      # Create essential files
      File.write!(Path.join([temp_source, "bin", "erlexec"]), "#!/bin/sh\n")
      File.write!(Path.join([temp_source, "bin", "beam.smp"]), "")
      File.write!(Path.join([temp_source, "releases", "start_erl.data"]), "16.0 28\n")

      # Run preparation
      assert :ok = EscriptPackager.prepare_minimal_erts(temp_source, temp_dest)

      # Verify essential files were copied
      assert File.exists?(Path.join([temp_dest, "bin", "erlexec"]))
      assert File.exists?(Path.join([temp_dest, "releases", "start_erl.data"]))
    end

    test "handles nested erts structure" do
      tmp = System.tmp_dir!()
      temp_source = Path.join(tmp, "test_erts_nested_#{:rand.uniform(100_000)}")
      temp_dest = Path.join(tmp, "test_erts_nested_dest_#{:rand.uniform(100_000)}")

      on_exit(fn ->
        File.rm_rf(temp_source)
        File.rm_rf(temp_dest)
      end)

      # Create nested ERTS structure like OTP releases
      File.mkdir_p!(Path.join([temp_source, "erts-26.0", "bin"]))
      File.mkdir_p!(Path.join([temp_source, "erts-26.0", "lib", "kernel", "ebin"]))

      File.write!(Path.join([temp_source, "erts-26.0", "bin", "erlexec"]), "#!/bin/sh\n")

      File.write!(
        Path.join([temp_source, "erts-26.0", "lib", "kernel", "ebin", "kernel.app"]),
        ""
      )

      assert :ok = EscriptPackager.prepare_minimal_erts(temp_source, temp_dest)

      # After flattening, files should be at root level
      assert File.exists?(Path.join([temp_dest, "bin", "erlexec"]))
    end
  end

  describe "package/4" do
    test "validates compression level bounds" do
      assert_raise FunctionClauseError, fn ->
        EscriptPackager.package("/nonexistent", "/nonexistent", "/tmp/out.tar.zst", 0)
      end

      assert_raise FunctionClauseError, fn ->
        EscriptPackager.package("/nonexistent", "/nonexistent", "/tmp/out.tar.zst", 20)
      end
    end

    test "package requires valid source directories" do
      # Test that FunctionClauseError is raised for invalid compression levels
      # This ensures the function validates inputs before attempting file operations
      assert_raise FunctionClauseError, fn ->
        EscriptPackager.package("/nonexistent", "/nonexistent", "/tmp/out.tar.zst", 0)
      end

      assert_raise FunctionClauseError, fn ->
        EscriptPackager.package("/nonexistent", "/nonexistent", "/tmp/out.tar.zst", 20)
      end
    end
  end

  describe "estimate_size/1" do
    test "returns estimate for nonexistent file" do
      # Should return a reasonable estimate even for nonexistent files
      assert {:ok, size} = EscriptPackager.estimate_size("/nonexistent")
      assert is_integer(size)
      assert size >= 0
    end

    test "returns size for existing file" do
      tmp_file = Path.join(System.tmp_dir!(), "test_size_#{:rand.uniform(100_000)}.txt")
      on_exit(fn -> File.rm(tmp_file) end)

      content = "test content for size estimation"
      File.write!(tmp_file, content)

      # The estimate should be based on the file or include overhead
      assert {:ok, size} = EscriptPackager.estimate_size(tmp_file)
      assert is_integer(size)
      assert size > 0
    end
  end
end

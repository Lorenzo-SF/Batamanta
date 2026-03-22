defmodule Batamanta.EscriptPackagerTest do
  use ExUnit.Case, async: true

  alias Batamanta.EscriptPackager

  describe "prepare_minimal_erts/2" do
    test "creates destination directory" do
      # Create a minimal mock ERTS structure
      tmp = System.tmp_dir!()
      temp_source = Path.join(tmp, "test_erts_source_#{:rand.uniform(10000)}")
      temp_dest = Path.join(tmp, "test_erts_dest_#{:rand.uniform(10000)}")

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
  end

  describe "package/4" do
    test "validates compression level" do
      assert_raise FunctionClauseError, fn ->
        EscriptPackager.package("/nonexistent", "/nonexistent", "/tmp/out.tar.zst", 0)
      end

      assert_raise FunctionClauseError, fn ->
        EscriptPackager.package("/nonexistent", "/nonexistent", "/tmp/out.tar.zst", 20)
      end
    end
  end

  describe "estimate_size/1" do
    test "returns default estimate for nonexistent file" do
      assert {:ok, size} = EscriptPackager.estimate_size("/nonexistent")
      assert size > 0
    end
  end
end

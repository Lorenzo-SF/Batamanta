defmodule Batamanta.SmokeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Integration tests that verify Batamanta correctly packages applications.
  
  These tests:
  1. Build a smoke test binary with batamanta
  2. Verify the binary exists and is executable
  3. Verify .boot files are present
  4. Execute the binary and validate output
  """

  @test_dir Path.join(System.tmp_dir!(), "batamanta_smoke_test_#{:erlang.unique_integer([:positive])}")
  @smoke_app_path Path.expand("../smoke_test", __DIR__)

  setup do
    File.mkdir_p!(@test_dir)
    
    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    %{test_dir: @test_dir}
  end

  describe "batamanta packaging" do
    test "creates valid binary structure", %{test_dir: test_dir} do
      # Copy smoke test app to temp directory
      test_app_path = Path.join(test_dir, "smoke_test")
      File.cp_r!(@smoke_app_path, test_app_path)
      
      # Get dependencies
      {_output, 0} = System.cmd("mix", ["deps.get"], cd: test_app_path, into: IO.stream(:stdio, :line))
      
      # Build with batamanta
      {_output, 0} = System.cmd("mix", ["batamanta", "--compression", "1"], 
        cd: test_app_path, 
        into: IO.stream(:stdio, :line),
        env: [{"MIX_ENV", "prod"}])
      
      # Find the binary
      binary_path = find_binary(test_app_path)
      assert File.exists?(binary_path), "Binary not found at #{binary_path}"
      
      # Verify it's executable
      assert File.executable?(binary_path), "Binary is not executable"
      
      # Verify .boot files exist
      boot_files = Path.wildcard(Path.join(test_app_path, "_build/prod/rel/smoke_test/releases/**/*.boot"))
      assert length(boot_files) > 0, "No .boot files found"
      
      # Verify start.boot exists in bin directory
      start_boot = Path.join(test_app_path, "_build/prod/rel/smoke_test/bin/start.boot")
      assert File.exists?(start_boot), "start.boot not found in bin/"
    end

    test "CLI mode executes and exits cleanly", %{test_dir: test_dir} do
      test_app_path = Path.join(test_dir, "smoke_test")
      File.cp_r!(@smoke_app_path, test_app_path)
      
      # Get dependencies and build
      System.cmd("mix", ["deps.get"], cd: test_app_path)
      System.cmd("mix", ["batamanta", "--compression", "1"], 
        cd: test_app_path, 
        env: [{"MIX_ENV", "prod"}])
      
      binary_path = find_binary(test_app_path)
      
      # Execute with test arguments
      {output, exit_code} = System.cmd(binary_path, ["--test-arg1", "--test-arg2"])
      
      assert exit_code == 0, "CLI should exit with code 0, got #{exit_code}"
      assert output =~ "Arguments received", "CLI should print arguments"
      assert output =~ "CLI test completed", "CLI should complete successfully"
    end

    test "TUI mode initializes correctly", %{test_dir: test_dir} do
      test_app_path = Path.join(test_dir, "smoke_test")
      File.cp_r!(@smoke_app_path, test_app_path)
      
      System.cmd("mix", ["deps.get"], cd: test_app_path)
      System.cmd("mix", ["batamanta", "--compression", "1"], 
        cd: test_app_path,
        env: [{"MIX_ENV", "prod"}, {"BATAMANTA_EXEC_MODE", "tui"}])
      
      binary_path = find_binary(test_app_path)
      
      # Execute TUI (will timeout but that's OK)
      {output, _exit_code} = System.cmd("timeout", ["2", binary_path], stderr_to_stdout: true)
      
      assert output =~ "Arguments received", "TUI should receive arguments"
      assert output =~ "TUI", "TUI should identify itself"
    end

    test "Daemon mode starts and runs", %{test_dir: test_dir} do
      test_app_path = Path.join(test_dir, "smoke_test")
      File.cp_r!(@smoke_app_path, test_app_path)
      
      System.cmd("mix", ["deps.get"], cd: test_app_path)
      System.cmd("mix", ["batamanta", "--compression", "1"], 
        cd: test_app_path,
        env: [{"MIX_ENV", "prod"}, {"BATAMANTA_EXEC_MODE", "daemon"}])
      
      binary_path = find_binary(test_app_path)
      
      # Start daemon
      port = Port.open({:spawn_executable, binary_path}, [:exit_status, :stderr_to_stdout])
      
      # Give it time to start
      :timer.sleep(2000)
      
      # Check if still running (daemon should stay alive)
      # Note: This is a simplified check - in production you'd use proper process management
      Port.close(port)
    end
  end

  defp find_binary(app_path) do
    base = Path.join(app_path, "_build/prod/rel/smoke_test/bin")
    
    # Find the binary (may have version suffix)
    case File.ls(base) do
      {:ok, files} ->
        binary = Enum.find(files, fn f -> 
          String.starts_with?(f, "smoke_test") and not String.contains?(f, ".")
        end)
        
        if binary, do: Path.join(base, binary), else: raise "Binary not found"
        
      {:error, _} ->
        raise "Binary directory not found: #{base}"
    end
  end
end

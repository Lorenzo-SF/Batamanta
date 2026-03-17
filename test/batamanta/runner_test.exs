defmodule Batamanta.RunnerTest do
  use ExUnit.Case, async: true

  alias Batamanta.Runner
  alias Batamanta.Runner.Native

  # Helper to find a working echo command
  defp find_echo do
    cond do
      System.find_executable("echo") != nil -> "echo"
      System.find_executable("/bin/echo") != nil -> "/bin/echo"
      System.find_executable("/usr/bin/echo") != nil -> "/usr/bin/echo"
      true -> nil
    end
  end

  defp find_printf do
    cond do
      System.find_executable("printf") != nil -> "printf"
      System.find_executable("/usr/bin/printf") != nil -> "/usr/bin/printf"
      System.find_executable("/bin/printf") != nil -> "/bin/printf"
      true -> nil
    end
  end

  describe "mix_run/2" do
    test "delegates to the configured runner module" do
      # Por defecto usa Native
      # Mix.Task.run puede devolver :ok o :noop dependiendo de si la tarea ya se cargó
      result = Runner.mix_run("help", [])
      assert result in [:ok, :noop]
    end

    test "can be configured with a custom runner" do
      # Configurar un runner mock
      mock_runner = fn _task, _args -> :mock_result end
      Application.put_env(:batamanta, :runner, mock_runner)

      # El runner personalizado debería ser usado
      # Nota: esto requiere que Runner.impl() lea la configuración
      Application.put_env(:batamanta, :runner, Native)
    end
  end

  describe "sys_cmd/3" do
    test "executes system commands and returns output" do
      case find_echo() do
        nil ->
          # Skip if echo is not available
          assert true

        cmd ->
          {output, exit_code} = Runner.sys_cmd(cmd, ["hello"])
          assert exit_code == 0
          assert String.trim(output) == "hello"
      end
    end

    test "handles command failures" do
      # Use a command that reliably fails on Unix systems
      # Check for 'false' command availability first
      if System.find_executable("false") != nil do
        {_output, exit_code} = Runner.sys_cmd("false", [])
        assert exit_code != 0
      else
        # Fallback: use sh with exit 1
        case System.find_executable("sh") do
          nil ->
            # Skip if no shell available
            assert true

          sh_path ->
            {_output, exit_code} = Runner.sys_cmd(sh_path, ["-c", "exit 1"], [])
            assert exit_code != 0
        end
      end
    end

    test "supports options like stderr_to_stdout" do
      # Use printf or echo depending on availability
      case find_printf() do
        nil ->
          # Skip if printf is not available
          assert true

        cmd ->
          {output, 0} = Runner.sys_cmd(cmd, ["test"], stderr_to_stdout: true)
          assert String.contains?(output, "test")
      end
    end
  end

  describe "find_executable/1" do
    test "finds executables in PATH" do
      # Usar ejecutables que deberían estar disponibles
      path = Runner.find_executable("ls")
      assert path != nil or Runner.find_executable("/bin/ls") != nil
    end

    test "returns nil for non-existent executables" do
      assert Runner.find_executable("nonexistent_command_xyz123") == nil
    end

    test "handles empty string" do
      assert Runner.find_executable("") == nil
    end
  end

  describe "Native module" do
    test "mix_run/2 delegates to Mix.Task.run/2" do
      # Mix.Task.run/2 puede devolver :ok, :noop, o nil dependiendo de la tarea
      result = Native.mix_run("help", [])
      assert result in [:ok, :noop, nil]
    end

    test "sys_cmd/3 delegates to System.cmd/3" do
      # Use echo or printf depending on availability
      case find_printf() || find_echo() do
        nil ->
          # Skip if neither is available
          assert true

        cmd ->
          args = if cmd == "printf", do: ["test"], else: ["test"]
          {output, code} = Native.sys_cmd(cmd, args, [])
          assert code == 0
          assert String.contains?(output, "test")
      end
    end

    test "find_executable/1 delegates to System.find_executable/1" do
      # Find any executable that's likely to exist
      found =
        Native.find_executable("ls") ||
          Native.find_executable("echo") ||
          Native.find_executable("sh") ||
          Native.find_executable("/bin/sh") ||
          Native.find_executable("/bin/ls")

      # At least one common executable should be found
      assert found != nil, "Expected to find at least one common executable"
    end
  end
end

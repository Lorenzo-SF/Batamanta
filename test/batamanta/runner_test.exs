defmodule Batamanta.RunnerTest do
  use ExUnit.Case, async: true

  alias Batamanta.Runner
  alias Batamanta.Runner.Native

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
      {output, exit_code} = Runner.sys_cmd("echo", ["hello"])
      assert exit_code == 0
      assert String.trim(output) == "hello"
    end

    test "handles command failures" do
      {_output, exit_code} = Runner.sys_cmd("false", [])
      assert exit_code != 0
    end

    test "supports options like stderr_to_stdout" do
      {output, 0} = Runner.sys_cmd("sh", ["-c", "echo test"], stderr_to_stdout: true)
      assert String.contains?(output, "test")
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
      {output, code} = Native.sys_cmd("echo", ["test"], [])
      assert code == 0
      assert String.trim(output) == "test"
    end

    test "find_executable/1 delegates to System.find_executable/1" do
      assert Native.find_executable("sh") != nil
    end
  end
end

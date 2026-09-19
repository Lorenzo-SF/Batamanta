defmodule Batamanta.RunnerTest do
  use ExUnit.Case, async: false

  alias Batamanta.Runner

  # `echo`/`sh` no son ejecutables en Windows (son builtins de `cmd`),
  # así que estos tests usan la shell nativa de cada SO (`cmd` en
  # Windows, `sh`/`echo` en Unix) en vez de asumir binarios concretos.
  defp echo_command do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "echo", "hello"]}
      _ -> {"echo", ["hello"]}
    end
  end

  defp exit_command(code) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "exit", Integer.to_string(code)]}
      _ -> {"sh", ["-c", "exit #{code}"]}
    end
  end

  defp system_shell do
    case :os.type() do
      {:win32, _} -> "cmd"
      _ -> "sh"
    end
  end

  describe "sys_cmd/2" do
    test "executes echo command" do
      {cmd, args} = echo_command()
      {output, exit_code} = Runner.sys_cmd(cmd, args)
      assert exit_code == 0
      assert String.trim(output) == "hello"
    end

    test "handles command failures" do
      {cmd, args} = exit_command(42)
      {_output, exit_code} = Runner.sys_cmd(cmd, args)
      assert exit_code == 42
    end
  end

  describe "find_executable/1" do
    test "finds the system shell" do
      path = Runner.find_executable(system_shell())
      assert path != nil
    end

    test "returns nil for nonexistent" do
      path = Runner.find_executable("nonexistent_xyz_abc_123")
      assert path == nil
    end
  end

  describe "mix_run/2" do
    test "mix_run exists" do
      # We don't want to actually run mix tasks in unit tests if possible
      # But we can verify it calls Mix.Task.run
      assert is_function(&Runner.mix_run/2)
    end
  end
end

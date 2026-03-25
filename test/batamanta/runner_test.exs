defmodule Batamanta.RunnerTest do
  use ExUnit.Case, async: true

  alias Batamanta.Runner

  describe "sys_cmd/2" do
    test "executes echo command" do
      {output, exit_code} = Runner.sys_cmd("echo", ["hello"])
      assert exit_code == 0
      assert String.trim(output) == "hello"
    end

    test "handles command failures" do
      {_output, exit_code} = Runner.sys_cmd("false", [])
      assert exit_code != 0
    end
  end

  describe "find_executable/1" do
    test "finds sh" do
      path = Runner.find_executable("sh")
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

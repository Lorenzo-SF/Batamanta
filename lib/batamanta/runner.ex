defmodule Batamanta.Runner do
  @moduledoc """
  Abstracts system and Mix commands for easier testing.

  Provides a behavior that allows mocking system commands during tests.
  """

  @doc """
  Runs a Mix task with the given arguments.
  """
  @spec mix_run(String.t(), [String.t()]) :: any()
  def mix_run(task, args), do: impl().mix_run(task, args)

  @doc """
  Executes a system command.
  """
  @spec sys_cmd(String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}
  def sys_cmd(cmd, args, opts \\ []), do: impl().sys_cmd(cmd, args, opts)

  @doc """
  Finds an executable in the system PATH.
  """
  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(cmd), do: impl().find_executable(cmd)

  defp impl, do: Application.get_env(:batamanta, :runner, Batamanta.Runner.Native)
end

defmodule Batamanta.Runner.Native do
  @moduledoc false

  def mix_run(task, args), do: Mix.Task.run(task, args)
  def sys_cmd(cmd, args, opts), do: System.cmd(cmd, args, opts)
  def find_executable(cmd), do: System.find_executable(cmd)
end

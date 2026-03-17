defmodule TestCli.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, args) do
    IO.puts("CLI application started")
    IO.puts("Arguments received: #{inspect(args)}")
    
    # Simulate CLI work - process arguments and exit
    case parse_args(args) do
      {:ok, :help} ->
        IO.puts("Usage: test_cli [--help] [--version]")
        IO.puts("This is a test CLI application")
        
      {:ok, :version} ->
        IO.puts("test_cli version 0.1.0")
        
      {:ok, :run} ->
        IO.puts("Running CLI task...")
        IO.puts("Task completed successfully")
        
      {:error, reason} ->
        IO.puts("Error: #{reason}")
    end
    
    # CLI should exit cleanly after completing its task
    :ignore
  end

  defp parse_args(args) do
    cond do
      "--help" in args or "-h" in args -> {:ok, :help}
      "--version" in args or "-v" in args -> {:ok, :version}
      true -> {:ok, :run}
    end
  end
end

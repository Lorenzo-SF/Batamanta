defmodule TestCli.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    IO.puts("Test CLI application started")
    :ignore
  end
end

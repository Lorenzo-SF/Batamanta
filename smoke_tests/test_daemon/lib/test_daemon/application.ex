defmodule TestDaemon.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    IO.puts("Test Daemon application started")
    
    children = [
      {Task, fn ->
        :timer.sleep(:infinity)
      end}
    ]

    opts = [strategy: :one_for_one, name: TestDaemon.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule TestDaemon.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, args) do
    IO.puts("Daemon application started")
    IO.puts("Arguments received: #{inspect(args)}")
    
    # Daemon should print args and then run indefinitely
    IO.puts("Daemon is now running in background...")
    IO.puts("PID: #{:os.getpid()}")
    IO.puts("Started at: #{DateTime.utc_now() |> DateTime.to_string()}")
    
    # Start a supervisor to keep the daemon running
    children = [
      {Task, fn ->
        # Main daemon loop - runs forever
        daemon_loop()
      end}
    ]

    opts = [strategy: :one_for_one, name: TestDaemon.Supervisor]
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        IO.puts("Daemon supervisor started: #{inspect(pid)}")
        {:ok, pid}
        
      {:error, reason} ->
        IO.puts("Daemon supervisor failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp daemon_loop do
    # Daemon main loop - should run indefinitely
    receive do
      :stop ->
        IO.puts("Daemon received stop signal")
        :ok
    after
      # Timeout to prevent blocking forever without messages
      1000 ->
        # Heartbeat - daemon is alive
        daemon_loop()
    end
  end
end

defmodule TestDaemon do
  @moduledoc """
  Smoke test Daemon application.

  Designed to run as a Batamanta daemon (execution_mode: :daemon):
  - Starts, prints system info
  - Creates a signal file to prove it ran
  - Terminates cleanly with exit code 0
  """
  use Application

  @impl true
  def start(_type, _args) do
    IO.puts("\n🚀 BATAMANTA DAEMON SMOKE TEST\n")

    # System info
    {os_type, os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    pid = :os.getpid()

    IO.puts("📊 System: #{os_type}/#{os_version} (#{arch})")
    IO.puts("📊 PID: #{pid}\n")

    # Create signal file
    signal_file = "daemon_alive.txt"

    content = """
    DAEMON_OK
    timestamp: #{System.system_time(:second)}
    pid: #{pid}
    node: #{node()}
    """

    File.write!(signal_file, content)
    IO.puts("✅ Signal file created: #{signal_file}")
    IO.puts("✅ Daemon smoke test completed successfully\n")

    # Start a minimal supervisor (Application requires it) and then stop cleanly
    children = []
    opts = [strategy: :one_for_one, name: TestDaemon.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup_pid} ->
        # Schedule a clean shutdown so we exit with code 0
        spawn(fn ->
          Process.sleep(500)
          IO.puts("👋 Shutting down cleanly...")
          System.stop(0)
        end)

        {:ok, sup_pid}

      error ->
        error
    end
  end
end

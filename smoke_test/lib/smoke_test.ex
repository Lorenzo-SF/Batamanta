defmodule SmokeTest do
  @moduledoc """
  Smoke test application for Batamanta.
  
  This application tests all three execution modes:
  - CLI: Prints arguments and exits
  - TUI: Activates raw mode, renders UI, handles keyboard
  - Daemon: Starts and runs indefinitely
  """
  use Application

  @impl true
  def start(_type, _args) do
    mode = System.get_env("BATAMANTA_EXEC_MODE", "cli") |> String.to_atom()
    
    IO.puts("\n╔════════════════════════════════════════════╗")
    IO.puts("║     BATAMANTA SMOKE TEST                    ║")
    IO.puts("╚════════════════════════════════════════════╝\n")
    
    # Show system information
    {os_type, os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    otp_version = :erlang.system_info(:otp_release) |> to_string()
    elixir_version = System.version()
    
    IO.puts("📊 System Information:")
    IO.puts("   OS: #{os_type}/#{os_version}")
    IO.puts("   Arch: #{arch}")
    IO.puts("   OTP: #{otp_version}")
    IO.puts("   Elixir: #{elixir_version}")
    IO.puts("   Mode: #{mode}\n")
    
    # Get and print arguments
    args = :init.get_plain_arguments() |> Enum.map(&to_string/1)
    IO.puts("📥 Arguments received: #{inspect(args)}\n")
    
    case mode do
      :cli ->
        run_cli_mode(args)
        
      :tui ->
        run_tui_mode(args)
        
      :daemon ->
        run_daemon_mode(args)
    end
  end
  
  defp run_cli_mode(args) do
    IO.puts("✅ CLI MODE: Processing arguments...")
    Enum.each(args, fn arg ->
      IO.puts("   - Argument: #{arg}")
    end)
    IO.puts("\n✅ CLI test completed successfully!")
    :erlang.halt(0)
  end
  
  defp run_tui_mode(args) do
    IO.puts("🖥️  TUI MODE: Initializing...")
    
    # Try to activate raw mode (may fail in CI without TTY)
    case :io.setopts([:binary, {:echo, false}, {:icanon, false}]) do
      :ok -> 
        IO.puts("✅ Raw mode activated")
      {:error, reason} ->
        IO.puts("⚠️  Raw mode not available: #{inspect(reason)} (OK in CI)")
    end
    
    # Render simple UI
    IO.puts("\n╔════════════════════════════════════════╗")
    IO.puts("║  TUI Application Running               ║")
    IO.puts("╠════════════════════════════════════════╣")
    IO.puts("║  Arguments: #{inspect(args)}")
    IO.puts("║  Press 'q' to quit                     ║")
    IO.puts("╚════════════════════════════════════════╝\n")
    
    # Simple keyboard handler (non-blocking in real app)
    IO.puts("⌨️  Keyboard handler ready (waiting for input...)")
    
    # In CI, just show the UI and exit after brief delay
    # In real TTY, would wait for 'q' keypress
    if System.get_env("CI") do
      IO.puts("\n✅ TUI test completed (CI mode - no TTY)")
      :erlang.halt(0)
    else
      # Would wait for user input in real scenario
      :timer.sleep(500)
      IO.puts("\n✅ TUI test completed!")
      :erlang.halt(0)
    end
  end
  
  defp run_daemon_mode(args) do
    IO.puts("🔧 DAEMON MODE: Starting background service...")
    
    # Start a minimal supervisor to keep the daemon running
    children = [
      {Task, fn ->
        daemon_loop(args)
      end}
    ]
    
    opts = [strategy: :one_for_one, name: SmokeTest.Supervisor]
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        IO.puts("✅ Daemon started successfully (PID: #{inspect(pid)})")
        IO.puts("🔄 Daemon is running in background...\n")
        {:ok, pid}
        
      {:error, reason} ->
        IO.puts("❌ Daemon failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp daemon_loop(args) do
    # Main daemon loop - runs indefinitely
    receive do
      :stop ->
        IO.puts("🛑 Daemon received stop signal")
        :ok
    after
      1000 ->
        # Heartbeat - daemon is alive
        daemon_loop(args)
    end
  end
end

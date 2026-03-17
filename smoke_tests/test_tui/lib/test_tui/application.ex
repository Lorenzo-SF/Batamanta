defmodule TestTui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, args) do
    IO.puts("TUI application started")
    IO.puts("Arguments received: #{inspect(args)}")
    
    # Try to initialize raw mode for TUI
    case initialize_tui() do
      :ok ->
        IO.puts("TUI initialized successfully")
        IO.puts("Rendering UI...")
        
        # Render a simple TUI frame
        render_ui()
        
        # Check for keyboard input (non-blocking)
        check_keyboard()
        
        # Cleanup and exit
        cleanup_tui()
        IO.puts("TUI shutdown complete")
        :ignore
        
      {:error, reason} ->
        IO.puts("TUI initialization failed: #{reason}")
        # Still exit cleanly - TUI attempted to start
        :ignore
    end
  end

  defp initialize_tui do
    # Try to set raw mode - this is what TUI apps do
    try do
      # Check if we have a terminal
      if Process.get(:tty_available, true) do
        :ok
      else
        {:error, "no terminal"}
      end
    rescue
      _ -> {:error, "raw mode not available"}
    end
  end

  defp render_ui do
    # Simulate TUI rendering with ANSI codes
    IO.write("\e[2J")  # Clear screen
    IO.write("\e[H")   # Move cursor home
    
    IO.puts("╔════════════════════════════╗")
    IO.puts("║     Test TUI Application   ║")
    IO.puts("╠════════════════════════════╣")
    IO.puts("║ Status: Running            ║")
    IO.puts("║ Press 'q' to quit          ║")
    IO.puts("╚════════════════════════════╝")
    
    :timer.sleep(100)  # Small delay to simulate rendering
  end

  defp check_keyboard do
    # Attempt to read keyboard input (non-blocking simulation)
    # In a real TUI, this would use :prim_inet.getopts or similar
    IO.puts("Keyboard handler ready")
    :timer.sleep(50)
  end

  defp cleanup_tui do
    # Reset terminal settings
    IO.write("\e[?25h")  # Show cursor
    IO.write("\e[0m")    # Reset colors
  end
end

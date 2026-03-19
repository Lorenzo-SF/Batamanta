defmodule TestTui do
  @moduledoc """
  Smoke test TUI application.

  This application demonstrates proper TUI behavior:
  - Raw terminal mode for keyboard input
  - Screen manipulation without escape sequences leaking
  - Clean exit with terminal restoration
  - Interactive menu navigation
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Get raw arguments
    args =
      :init.get_plain_arguments()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == "--"))

    # 🔴 CRÍTICO: Configurar terminal en modo raw para TUI
    # Esto previene que las secuencias de escape se muestren como [[C^^, [[A^, etc.
    enter_raw_mode()

    # Start the TUI in a linked process so we can monitor it
    spawn_link(fn ->
      try do
        run_tui(args)
      after
        # 🔴 CRÍTICO: Restaurar terminal SIEMPRE al salir
        restore_terminal()
      end
    end)

    # Return :ok - the spawned process handles the TUI
    {:ok, self()}
  end

  @doc """
  Enters raw mode for direct character reading without line buffering.

  In raw mode, keypresses are available immediately without pressing Enter.
  Call `restore_mode/0` in an `on_exit` callback or `try/after` block.
  """
  @spec enter_raw_mode() :: :ok
  def enter_raw_mode do
    # Disable echo and line buffering via stty
    case System.cmd("stty", ["-echo", "-icanon", "min", "1"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :ok
    end

    :ok
  end

  @doc """
  Restores normal terminal mode (line buffering, echo).
  """
  @spec restore_terminal() :: :ok
  def restore_terminal do
    case System.cmd("stty", ["echo", "icanon"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :ok
    end

    :ok
  end

  defp run_tui(args) do
    # Clear screen and show header
    clear_screen()

    IO.puts("\n╔════════════════════════════════════════════╗")
    IO.puts("║     BATAMANTA TUI SMOKE TEST              ║")
    IO.puts("║     [Navegación: Flechas / Q = Salir]    ║")
    IO.puts("╚════════════════════════════════════════════╝\n")

    # Show system info
    {os_type, os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    IO.puts("📊 System: #{os_type}/#{os_version} (#{arch})\n")

    # Demo menu
    menu_items = [
      {"Ver argumentos", fn -> show_args_demo(args) end},
      {"Demo interactiva", &run_interactive_demo/0},
      {"Test de teclado", &keyboard_test/0},
      {"Salir", fn -> :exit end}
    ]

    result = run_menu(menu_items, 0)

    case result do
      :exit ->
        IO.puts("\n✅ TUI exited cleanly!")
        :ok

      _ ->
        # Volver al menú después de cada acción
        run_tui(args)
    end
  end

  defp clear_screen do
    # ANSI clear screen
    IO.write("\e[2J\e[H")
  end

  defp run_menu(items, selected_index) do
    render_menu(items, selected_index)

    # Read input from user
    input = IO.gets("")

    case input do
      nil ->
        :exit

      :eof ->
        # EOF from pipe/redirect - exit cleanly
        :exit

      "" ->
        run_menu(items, selected_index)

      <<"\n">> ->
        # Ignore standalone newlines (shouldn't happen in raw mode)
        run_menu(items, selected_index)

      <<key::utf8, "\n">> ->
        # Single key followed by newline (common in raw mode with some terminals)
        handle_keypress(items, selected_index, key)

      <<key::utf8>> ->
        handle_keypress(items, selected_index, key)
    end
  end

  defp handle_keypress(items, selected_index, 27) do
    # Escape sequence - read more bytes
    rest = IO.gets("")
    handle_escape_sequence(items, selected_index, rest)
  end

  defp handle_keypress(items, selected_index, 13) do
    # Enter key
    execute_selected(items, selected_index)
  end

  defp handle_keypress(_items, _selected_index, key) when key == ?q or key == ?Q do
    :exit
  end

  defp handle_keypress(items, selected_index, key) when key == ?j or key == ?J do
    # Vim-style down
    new_index = rem(selected_index + 1, length(items))
    run_menu(items, new_index)
  end

  defp handle_keypress(items, selected_index, key) when key == ?k or key == ?K do
    # Vim-style up
    new_index = rem(selected_index - 1 + length(items), length(items))
    run_menu(items, new_index)
  end

  defp handle_keypress(items, selected_index, _key) do
    run_menu(items, selected_index)
  end

  defp handle_escape_sequence(items, selected_index, <<91, 65, _rest::binary>>) do
    # Up arrow
    new_index = rem(selected_index - 1 + length(items), length(items))
    render_menu(items, new_index)
    run_menu(items, new_index)
  end

  defp handle_escape_sequence(items, selected_index, <<91, 66, _rest::binary>>) do
    # Down arrow
    new_index = rem(selected_index + 1, length(items))
    render_menu(items, new_index)
    run_menu(items, new_index)
  end

  defp handle_escape_sequence(items, selected_index, _rest) do
    run_menu(items, selected_index)
  end

  defp render_menu(items, selected_index) do
    clear_screen()

    IO.puts("\n╔════════════════════════════════════════════╗")
    IO.puts("║     BATAMANTA TUI SMOKE TEST              ║")
    IO.puts("║     [↑↓: Navegar | Enter: Seleccionar]   ║")
    IO.puts("╚════════════════════════════════════════════╝\n")

    Enum.with_index(items)
    |> Enum.each(fn {{label, _}, idx} ->
      if idx == selected_index do
        IO.puts("  ▶ #{label}")
      else
        IO.puts("    #{label}")
      end
    end)

    IO.puts("\n  [Q] Salir\n")
  end

  defp execute_selected(items, index) do
    {_, action} = Enum.at(items, index)
    result = action.()

    case result do
      :exit -> :exit
      _ -> run_menu(items, index)
    end
  end

  defp show_args_demo(args) do
    clear_screen()
    IO.puts("\n📋 Argumentos Recibidos:\n")

    case args do
      [] ->
        IO.puts("   (sin argumentos)")

      other ->
        Enum.with_index(other, 1)
        |> Enum.each(fn {arg, idx} ->
          IO.puts("   [#{idx}] #{arg}")
        end)
    end

    IO.puts("\n✅ TUI: Argumentos mostrados correctamente")
    IO.puts("\nPresiona Enter para volver...")
    IO.gets("")
  end

  defp run_interactive_demo do
    clear_screen()
    IO.puts("\n🎮 Interactive TUI Demo\n")

    items = ["manzana", "pera", "naranja", "uva"]

    IO.puts("📋 Lista de items:")

    Enum.each(items, fn item ->
      IO.puts("   • #{item}")
      Process.sleep(100)
    end)

    IO.puts("\n🔄 Procesando...")
    Process.sleep(200)

    IO.puts("✅ Procesado #{length(items)} items correctamente")

    IO.puts("\nPresiona Enter para volver...")
    IO.gets("")
  end

  defp keyboard_test do
    clear_screen()
    IO.puts("\n⌨️  Keyboard Test\n")
    IO.puts("Presiona teclas (Q para salir)\n")

    read_keys([])
  end

  defp read_keys(keys) do
    # Leer input del usuario
    input = IO.gets("")

    case input do
      nil ->
        :ok

      "" ->
        read_keys(keys)

      <<key::utf8>> ->
        cond do
          key == ?q or key == ?Q ->
            :ok

          key == ?\n or key == ?\r ->
            read_keys(keys)

          true ->
            new_keys = [key | keys]
            IO.puts("  Key: #{key} (#{length(new_keys)} total)")
            read_keys(new_keys)
        end
    end
  end
end

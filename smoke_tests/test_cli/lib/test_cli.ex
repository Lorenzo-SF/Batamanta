defmodule TestCli do
  @moduledoc """
  Smoke test CLI application.

  This application demonstrates proper CLI behavior:
  - Reads arguments from command line
  - Processes input interactively
  - Outputs formatted results
  - Exits cleanly with proper status codes
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Get raw arguments from Erlang VM
    args =
      :init.get_plain_arguments()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == "--"))

    IO.puts("\n╔════════════════════════════════════════════╗")
    IO.puts("║     BATAMANTA CLI SMOKE TEST              ║")
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
    IO.puts("   Elixir: #{elixir_version}\n")

    case args do
      [] ->
        # No arguments: show usage
        show_usage()

      ["help" | _] ->
        show_usage()

      ["interactive"] ->
        # Interactive mode: demonstrate CLI capabilities
        run_interactive_demo()

      ["calc", expr | rest] ->
        # Calculator mode: evaluate expression
        evaluate_expression(expr, rest)

      other ->
        # Standard mode: show received arguments
        show_arguments(other)
    end

    # Give IO server time to flush buffers (critical for Linux)
    Process.sleep(50)
    :erlang.halt(0)
  end

  defp show_usage do
    IO.puts("""
    Usage: test_cli [OPTIONS] [ARGUMENTS]

    Options:
      help          Show this help message
      interactive   Run interactive demo
      calc <expr>   Evaluate mathematical expression

    Examples:
      test_cli arg1 arg2 arg3
      test_cli interactive
      test_cli calc "2 + 2"
    """)
  end

  defp show_arguments(args) do
    count = length(args)

    IO.puts("✅ CLI: Recibidos #{count} argumento(s)")
    IO.puts("\nArgumentos detallados:")

    Enum.with_index(args, 1)
    |> Enum.each(fn {arg, idx} ->
      IO.puts("   [#{idx}] #{arg}")
    end)

    # Demonstrate processing
    IO.puts("\n🔄 Procesando argumentos...")
    Process.sleep(100)

    # Show transformed output
    transformed = Enum.map(args, &String.upcase/1)
    IO.puts("📈 Transformados: #{inspect(transformed)}")

    IO.puts("\n✅ CLI test completed successfully!")
  end

  defp run_interactive_demo do
    IO.puts("🎮 Interactive CLI Demo\n")

    # Simulate interactive processing
    items = ["manzana", "pera", "naranja", "uva"]

    IO.puts("📋 Lista de items:")
    Enum.each(items, fn item ->
      IO.puts("   • #{item}")
      Process.sleep(50)
    end)

    IO.puts("\n🔄 Procesando...")
    Process.sleep(200)

    IO.puts("✅ Procesado #{length(items)} items correctamente")

    # Show that we can handle user-like input
    IO.puts("\n📝 Argumentos de prueba recibidos:")
    args = :init.get_plain_arguments() |> Enum.map(&to_string/1)
    IO.puts("   Raw: #{inspect(args)}")

    IO.puts("\n✅ Interactive demo completed!")
  end

  defp evaluate_expression(expr, _rest) do
    IO.puts("🧮 Calculator mode")
    IO.puts("   Expresión: #{expr}")

    # Simple evaluation (just for demo)
    result =
      case Integer.parse(expr) do
        {num, ""} -> num * 2
        :error -> "Expresión no válida (solo enteros simples)"
      end

    IO.puts("   Resultado: #{inspect(result)}")
    IO.puts("\n✅ Calculator mode completed!")
  end
end

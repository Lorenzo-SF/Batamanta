defmodule TestEscript.CLI do
  @moduledoc """
  Smoke test Escript application.

  This application demonstrates proper escript behavior:
  - Has a main/1 entry point (escript convention)
  - Reads arguments from command line
  - Processes input and outputs formatted results
  - Exits cleanly with proper status codes

  The escript format is different from releases:
  - Uses mix escript.build instead of mix release
  - No boot scripts needed
  - Self-contained binary with embedded Elixir
  - Requires ERTS runtime to execute
  """
  @version "0.1.0"

  @doc """
  Main entry point for the escript - called by Erlang VM.

  This function is the escript entry point, different from
  Application.start/2 used by releases.
  """
  def main(args) do
    IO.puts("\n╔════════════════════════════════════════════╗")
    IO.puts("║     BATAMANTA ESCRIPT SMOKE TEST          ║")
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
    IO.puts("   Version: #{@version}\n")

    # Process arguments
    result =
      case args do
        [] ->
          # No arguments: show usage
          show_usage()
          :ok

        ["--help" | _] ->
          show_help()
          :ok

        ["--version" | _] ->
          IO.puts("test_escript #{@version}")
          :ok

        ["info" | _] ->
          show_system_info()
          :ok

        ["process" | rest] ->
          process_args(rest)
          :ok

        ["transform" | rest] ->
          transform_args(rest)
          :ok

        ["calc" | rest] ->
          calc_args(rest)
          :ok

        other ->
          IO.puts("📥 Received #{length(other)} argument(s):")
          Enum.with_index(other, 1)
          |> Enum.each(fn {arg, idx} ->
            IO.puts("   [#{idx}] #{arg}")
          end)
          :ok
      end

    IO.puts("\n✅ Escript test completed successfully!")
    result
  end

  defp show_usage do
    IO.puts("""
    Usage: test_escript [COMMAND] [OPTIONS]

    Commands:
      help          Show this help message
      version       Show version information
      info          Display detailed system information
      process       Process arguments (uppercase transformation)
      transform     Transform arguments (lowercase)
      calc <expr>   Simple calculator (integers only)

    Examples:
      test_escript
      test_escript help
      test_escript info
      test_escript arg1 arg2 arg3
      test_escript transform foo BAR Baz
      test_escript calc "42 + 1"
    """)
  end

  defp show_help do
    IO.puts("""
    ╔════════════════════════════════════════════╗
    ║     BATAMANTA ESCRIPT SMOKE TEST HELP     ║
    ╚════════════════════════════════════════════╝

    This escript demonstrates:
    • Escript packaging format (mix escript.build)
    • Command-line argument parsing
    • Formatted output
    • Clean exit codes

    Key differences from releases:
    • Uses escript format instead of OTP release
    • Smaller binary size
    • Requires ERTS runtime
    • No boot scripts needed
    """)
  end

  defp show_system_info do
    IO.puts("🔍 Detailed System Information:\n")

    memory = :erlang.memory()
    total_mem = Keyword.get(memory, :total) |> format_bytes()
    processes = :erlang.system_info(:process_count)
    schedulers = :erlang.system_info(:schedulers)
    atom_count = :erlang.system_info(:atom_count)

    IO.puts("📦 Memory:")
    IO.puts("   Total: #{total_mem}")

    IO.puts("\n⚙️  Erlang:")
    IO.puts("   Processes: #{processes}")
    IO.puts("   Schedulers: #{schedulers}")
    IO.puts("   Atoms: #{atom_count}")

    IO.puts("\n📋 Environment:")
    IO.puts("   HOME: #{System.get_env("HOME", "unknown")}")
    IO.puts("   USER: #{System.get_env("USER", "unknown")}")
    IO.puts("   PWD: #{File.cwd!()}")

    IO.puts("\n✅ System info displayed!")
  end

  defp process_args(args) do
    if Enum.empty?(args) do
      IO.puts("⚠️  No arguments to process")
    else
      IO.puts("🔄 Processing #{length(args)} argument(s)...\n")

      transformed =
        Enum.map(args, fn arg ->
          {arg, String.upcase(arg)}
        end)

      IO.puts("   Original → Uppercase:")
      transformed
      |> Enum.with_index(1)
      |> Enum.each(fn {{orig, upper}, idx} ->
        IO.puts("   [#{idx}] #{orig} → #{upper}")
      end)

      IO.puts("\n✅ Arguments processed!")
    end
  end

  defp transform_args(args) do
    if Enum.empty?(args) do
      IO.puts("⚠️  No arguments to transform")
    else
      IO.puts("🔄 Transforming #{length(args)} argument(s)...\n")

      transformed =
        Enum.map(args, fn arg ->
          {arg, String.downcase(arg)}
        end)

      IO.puts("   Original → Lowercase:")
      transformed
      |> Enum.with_index(1)
      |> Enum.each(fn {{orig, lower}, idx} ->
        IO.puts("   [#{idx}] #{orig} → #{lower}")
      end)

      IO.puts("\n✅ Arguments transformed!")
    end
  end

  defp calc_args(args) do
    expr = Enum.join(args, " ")

    cond do
      expr == "" ->
        IO.puts("⚠️  No expression provided")

      true ->
        IO.puts("🧮 Calculator Mode\n")
        IO.puts("   Expression: #{expr}")

        result =
          case parse_simple_expr(expr) do
            {:ok, value} -> "#{expr} = #{value}"
            :error -> "Invalid expression (supported: integers and +, -, *, /)"
          end

        IO.puts("   Result: #{result}")
        IO.puts("\n✅ Calculation complete!")
    end
  end

  defp parse_simple_expr(expr) do
    # Very simple parser for expressions like "5 + 3"
    # Split by operators and parse
    result =
      cond do
        String.contains?(expr, "+") ->
          [a, b] = String.split(expr, "+", trim: true)
          parse_n(a) + parse_n(b)

        String.contains?(expr, "-") ->
          [a, b] = String.split(expr, "-", trim: true)
          parse_n(a) - parse_n(b)

        String.contains?(expr, "*") ->
          [a, b] = String.split(expr, "*", trim: true)
          parse_n(a) * parse_n(b)

        String.contains?(expr, "/") ->
          [a, b] = String.split(expr, "/", trim: true)
          if b == "0", do: :error, else: div(parse_n(a), parse_n(b))

        true ->
          :error
      end

    if result == :error, do: :error, else: {:ok, result}
  end

  defp parse_n(str) do
    {num, _} = Integer.parse(String.trim(str))
    num
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{div(bytes, 1_000_000_000)} GB"
      bytes >= 1_000_000 -> "#{div(bytes, 1_000_000)} MB"
      bytes >= 1_000 -> "#{div(bytes, 1_000)} KB"
      true -> "#{bytes} bytes"
    end
  end
end

defmodule TestReleaseCli.CLI do
  @moduledoc """
  CLI entry point for the release CLI smoke test.

  Invoked by the `.run` script via `eval 'TestReleaseCli.CLI.main()' -- "$@"`.
  """

  @doc """
  Main entry point. Prints system info and received arguments, then exits.
  """
  def main(args) do
    IO.puts("""
    ╔════════════════════════════════════════════╗
    ║     BATAMANTA RELEASE CLI SMOKE TEST       ║
    ╚════════════════════════════════════════════╝
    """)

    {os_type, os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    otp_version = :erlang.system_info(:otp_release) |> to_string()

    IO.puts("System: #{os_type}/#{os_version} #{arch}")
    IO.puts("OTP:    #{otp_version}")
    IO.puts("Args:   #{inspect(args)}")
    IO.puts("")

    if args == [] do
      IO.puts("No arguments provided — expected for basic smoke test.")
    else
      IO.puts("Received #{length(args)} argument(s):")
      Enum.with_index(args, 1) |> Enum.each(fn {a, i} -> IO.puts("  [#{i}] #{a}") end)
    end

    IO.puts("")
    IO.puts("Release CLI smoke test PASSED.")
  end
end

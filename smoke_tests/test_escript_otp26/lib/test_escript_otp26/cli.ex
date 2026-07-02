defmodule TestEscriptOtp26.CLI do
  @moduledoc """
  CLI entry point for the escript.
  """
  def main(args) do
    otp_version = :erlang.system_info(:otp_release) |> to_string()
    IO.puts("\n✅ TestEscriptOtp26 running with OTP #{otp_version}\n")
    args_summary = if args == [], do: "none", else: Enum.join(args, ", ")
    IO.puts("   Args: #{args_summary}")
    :ok
  end
end

defmodule TestReleaseOtp27 do
  @moduledoc """
  Smoke test release application.
  Prints the system OTP version and exits.
  """

  use Application

  @impl true
  def start(_type, _args) do
    otp_version = :erlang.system_info(:otp_release) |> to_string()
    IO.puts("\n✅ TestReleaseOtp27 running with OTP #{otp_version}\n")
    # Wait a little so output flushes
    Process.sleep(50)
    :erlang.halt(0)
  end
end

defmodule TestEscriptOtp26 do
  @moduledoc """
  Smoke test escript application.
  Prints the system OTP version and exits.
  """
  use Application

  @impl true
  def start(_type, _args) do
    otp_version = :erlang.system_info(:otp_release) |> to_string()
    IO.puts("\n✅ TestEscriptOtp26 running with OTP #{otp_version}\n")
    Process.sleep(50)
    :erlang.halt(0)
  end
end

defmodule TestBeamDaemon.CLI do
  @moduledoc """
  CLI entry point invoked by the daemon on every request.

  Smoke tests assert that this prints a per-invocation banner, the
  received args, and exits 0. We use `:persistent_term` for the
  invocation counter specifically to prove the BEAM stays alive across
  calls — if every call prints "invocation: 1", daemon mode isn't
  actually working.
  """

  @doc """
  main(args) — the daemon's runner calls this for every request.

  Note: when daemon mode is active, the BEAM stays alive between
  invocations, so any process state in this module persists. The smoke
  test only does I/O so that's irrelevant, but real consumers should
  design `main/1` to be safe to re-call.
  """
  def main(args) do
    invocation = :persistent_term.get({:test_beam_daemon, :invocation}, 0) + 1
    :persistent_term.put({:test_beam_daemon, :invocation}, invocation)

    IO.puts("""
    ╔════════════════════════════════════════════════════════╗
    ║     BATAMANTA DAEMON MODE SMOKE TEST                   ║
    ║     invocation: #{invocation}                                  ║
    ╚════════════════════════════════════════════════════════╝
    """)

    {os_type, _os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    otp_version = :erlang.system_info(:otp_release) |> to_string()

    IO.puts("System: #{os_type} #{arch}")
    IO.puts("OTP:    #{otp_version}")
    IO.puts("Args:   #{inspect(args)}")
    IO.puts("")
    IO.puts("Daemon-mode smoke test PASSED.")
  end
end

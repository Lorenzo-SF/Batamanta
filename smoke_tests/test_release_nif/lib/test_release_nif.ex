defmodule TestReleaseNif do
  @moduledoc """
  Smoke test release with `include_erts: false`.

  This is the exact configuration Delfos uses, and the exact one
  that used to crash the batamanta wrapper with
  `{load_failed,[supervisor,kernel,...]}` because ROOTDIR pointed
  to the release root (which has no kernel/ in lib/) instead of
  the bundled ERTS directory.
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Read a few core BEAM APIs whose backing modules are loaded
    # via the boot script's $ROOT/lib path. If ROOTDIR is wrong,
    # the VM crashes here with load_failed *before* this code runs.
    otp_version = :erlang.system_info(:otp_release) |> to_string()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    # Sanity check: try a supervisor primitive. If kernel/supervisor
    # did not load, this raises.
    {:ok, _sup} = Supervisor.start_link([], strategy: :one_for_one)

    IO.puts("\n✅ TestReleaseNif running with OTP #{otp_version} (#{arch})")
    IO.puts("   include_erts: false, kernel/stdlib loaded from bundled ERTS\n")

    Process.sleep(50)
    :erlang.halt(0)
  end
end

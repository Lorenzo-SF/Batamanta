defmodule TestBeamDaemon do
  @moduledoc """
  Smoke test for the BEAM daemon mode (the new `daemon:` config block).

  The smoke runner invokes this binary 15 times in a loop. With daemon
  mode enabled, the first call should pay the BEAM boot cost; the
  remaining 14 should hit the warm BEAM in single-digit milliseconds.

  This Application callback returns an empty supervisor. The CLI module
  is the entry point; the daemon dispatches to it on every request.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: TestBeamDaemon.Supervisor)
  end
end

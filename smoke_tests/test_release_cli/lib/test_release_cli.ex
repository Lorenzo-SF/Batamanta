defmodule TestReleaseCli do
  @moduledoc """
  Smoke test release CLI application.

  Tests the release format with `execution_mode: :cli`. The `.run` script
  invokes `TestReleaseCli.CLI.main/1` via Mix's `eval` command.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

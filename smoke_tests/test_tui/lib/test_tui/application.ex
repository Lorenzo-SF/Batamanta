defmodule TestTui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    IO.puts("Test TUI application started")
    :ignore
  end
end

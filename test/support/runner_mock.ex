defmodule Batamanta.Runner.Mock do
  @moduledoc """
  Mock implementation of Runner for testing.

  This module provides mock implementations of system commands
  and automatically handles cleanup of any temporary files created.
  """

  # Track files created during tests for cleanup
  defmodule State do
    @moduledoc false
    defstruct created_files: MapSet.new()

    def add_file(state, path) do
      %{state | created_files: MapSet.put(state.created_files, path)}
    end

    def cleanup(state) do
      Enum.each(state.created_files, &File.rm/1)
      %{state | created_files: MapSet.new()}
    end
  end

  use GenServer

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:sys_cmd, "zstd", args, _opts}, _from, state) do
    # When mocking zstd, we must create the dummy output file
    # the command looks like: ["-19", "--rm", "-f", in_file, "-o", out_file]
    if "-o" in args do
      out_idx = Enum.find_index(args, fn arg -> arg == "-o" end)
      out_file = Enum.at(args, out_idx + 1)
      File.write!(out_file, "dummy_zstd_payload")
      {:reply, {"success", 0}, State.add_file(state, out_file)}
    else
      {:reply, {"success", 0}, state}
    end
  end

  @impl true
  def handle_call({:sys_cmd, "strip", _args, _opts}, _from, state) do
    {:reply, {"success", 0}, state}
  end

  @impl true
  def handle_call({:sys_cmd, "upx", _args, _opts}, _from, state) do
    {:reply, {"success", 0}, state}
  end

  @impl true
  def handle_call({:sys_cmd, _cmd, _args, opts}, _from, state) do
    dir = Keyword.get(opts, :cd)

    if dir do
      base = Path.join([dir, "target", "x86_64-unknown-linux-musl", "release"])
      File.mkdir_p!(base)
      bin_path = Path.join(base, "batamanta_dispenser")
      File.write!(bin_path, "dummy_bin")
      {:reply, {"success", 0}, State.add_file(state, bin_path)}
    else
      {:reply, {"success", 0}, state}
    end
  end

  @impl true
  def handle_call({:find_executable, "cargo"}, _from, state) do
    {:reply, "/usr/bin/cargo", state}
  end

  @impl true
  def handle_call({:find_executable, "cross"}, _from, state) do
    {:reply, "/usr/bin/cross", state}
  end

  @impl true
  def handle_call({:find_executable, _}, _from, state) do
    {:reply, "/usr/bin/mocked_path", state}
  end

  @impl true
  def handle_call({:mix_run, "compile", _args}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mix_run, "release", _args}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    State.cleanup(state)
    {:reply, :ok, state}
  end

  @doc """
  Cleanup any files created during tests.
  Call this in setup_all/teardown_all callbacks.
  """
  def cleanup do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :cleanup)
    end
  end

  @doc """
  Stops the mock server.
  """
  def stop do
    if Process.whereis(__MODULE__) do
      GenServer.stop(__MODULE__)
    end
  end
end

defmodule Batamanta.Runner.CompiledMock do
  @moduledoc """
  Compiled mock functions for simple use cases.

  Use this when you don't need GenServer state tracking.
  For cleanup support, use Runner.Mock instead.
  """

  def mix_run("compile", _args), do: :ok
  def mix_run("release", _args), do: :ok

  def sys_cmd("zstd", args, _opts) do
    # When mocking zstd, we must create the dummy output file
    # the command looks like: ["-19", "--rm", "-f", in_file, "-o", out_file]
    if "-o" in args do
      out_idx = Enum.find_index(args, fn arg -> arg == "-o" end)
      out_file = Enum.at(args, out_idx + 1)
      File.write!(out_file, "dummy_zstd_payload")
    end

    {"success", 0}
  end

  def sys_cmd("strip", _args, _opts) do
    {"success", 0}
  end

  def sys_cmd("upx", _args, _opts) do
    {"success", 0}
  end

  def sys_cmd(_cmd, _args, opts) do
    dir = Keyword.get(opts, :cd)

    if dir do
      base = Path.join([dir, "target", "x86_64-unknown-linux-musl", "release"])
      File.mkdir_p!(base)
      File.write!(Path.join(base, "batamanta_dispenser"), "dummy_bin")
    end

    {"success", 0}
  end

  # Simulamos que las herramientas están instaladas
  def find_executable("cargo"), do: "/usr/bin/cargo"
  def find_executable("cross"), do: "/usr/bin/cross"
  def find_executable(_), do: "/usr/bin/mocked_path"

  def system_cmd(_cmd, _args, _opts \\ []), do: {"Mocked output", 0}
end

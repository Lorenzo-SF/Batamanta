defmodule TestDaemon do
  @moduledoc """
  Smoke test Daemon application.

  This application demonstrates proper daemon behavior:
  - Runs in background without terminal I/O
  - Creates signal file to prove it's running
  - Handles arguments for configuration
  - Stays alive until killed
  """
  use Supervisor

  # ---------- SUPERVISOR ----------
  @impl true
  def start(_args) do
    children = [
      # The daemon process itself
      {__MODULE__, :dummy}
    ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end

  # ---------- CHILD PROCESS ----------
  @impl true
  def init(_args) do
    # 👉 IMPORTANTE: imprimimos inmediatamente al iniciar el proceso hijo
    IO.puts("\n🚀 BATAMANTA DAEMON SMOKE TEST\n")

    # Mostrar información del sistema
    {os_type, os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    pid = :os.getpid()

    IO.puts("📊 System: #{os_type}/#{os_version} (#{arch})")
    IO.puts("📊 PID: #{pid}\n")

    # Leer argumentos (si los hay)
    args = _args

    case args do
      [] ->
        run_default_daemon()

      ["test" | _] ->
        run_test_daemon(args)

      other ->
        run_custom_daemon(other)
    end

    # Programar heartbeat periódico
    schedule_alive_check()

    # Mantener el proceso vivo indefinidamente
    {:ok, self()}
  end

  # ---------- ACCIONES ----------
  defp run_default_daemon do
    signal_file = "daemon_alive.txt"
    content = """
    DAEMON_OK
    timestamp: #{System.system_time(:second)}
    pid: #{:os.getpid()}
    node: #{node()}
    """

    File.write!(signal_file, content)
    IO.puts("✅ Signal file created: #{signal_file}")

    # Indicador de vida continua
    schedule_alive_check()
  end

  defp run_test_daemon(args) do
    test_file = "daemon_test_result.txt"
    File.write!(test_file, "TEST_PASSED\nargs: #{inspect(args)}\n")
    IO.puts("✅ Test 1: File creation")

    # Test 2: Información del proceso
    info = %{
      pid: :os.getpid(),
      uptime_ms: :erlang.system_time(:millisecond),
      memory: byte_size(:erlang.memory())
    }

    File.write!(test_file, "\ninfo: #{inspect(info)}\n", [:append])
    IO.puts("✅ Test 2: Process info collected")

    # Test 3: Tarea en background
    Task.start(fn ->
      Process.sleep(1000)
      File.write!(test_file, "\nbackground_task: completed\n", [:append])
    end)

    IO.puts("✅ Test 3: Background task started")
    IO.puts("\n📊 Results written to: #{test_file}")
    IO.puts("\n✅ All daemon tests passed!")

    schedule_alive_check()
  end

  defp run_custom_daemon(args) do
    config = parse_args(args)

    IO.puts("⚙️  Daemon configuration:")
    Enum.each(config, fn {key, value} -> IO.puts("   #{key}: #{value}") end)

    signal_file = config[:signal_file] || "daemon_custom.txt"
    content = """
    DAEMON_CUSTOM
    config: #{inspect(config)}
    timestamp: #{System.system_time(:second)}
    """

    File.write!(signal_file, content)
    IO.puts("\n✅ Custom daemon started: #{signal_file}")

    schedule_alive_check()
  end

  defp parse_args(args) do
    Enum.reduce(args, %{signal_file: "daemon_custom.txt"}, fn arg, acc ->
      case String.split(arg, "=", parts: 2) do
        ["signal_file", value] -> %{acc | signal_file: value}
        _ -> acc
      end
    end)
  end

  # ---------- HEARTBEAT ----------
  defp schedule_alive_check do
    Process.send_after(self(), :alive_check, 10_000)
  end

  @impl true
  def handle_info(:alive_check, state) do
    File.write!("daemon_heartbeat.txt", "#{System.system_time(:second)}\n", [:append])
    schedule_alive_check()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason) do
    # Permitir cierre ordenado si fuera necesario
    :ok
  end

  @impl true
  def init(args) do
    # Show system info
    IO.puts("\n🚀 BATAMANTA DAEMON SMOKE TEST\n")

    {os_type, os_version} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()
    pid = :os.getpid()

    IO.puts("📊 System: #{os_type}/#{os_version} (#{arch})")
    IO.puts("📊 PID: #{pid}\n")

    case args do
      [] ->
        # Default behavior: create signal file and wait
        run_default_daemon()

      ["test" | _] ->
        # Test mode: demonstrate daemon capabilities
        run_test_daemon(args)

      other ->
        # Custom mode: use arguments for configuration
        run_custom_daemon(other)
    end

    # Schedule periodic alive check (every 10 seconds)
    schedule_alive_check()

    {:ok, %{}}

    # The GenServer will now wait for messages (like :alive_check) and stay alive.
  end

  defp run_default_daemon do
    # Create signal file to prove daemon is running
    signal_file = "daemon_alive.txt"
    content = """
    DAEMON_OK
    timestamp: #{System.system_time(:second)}
    pid: #{:os.getpid()}
    node: #{node()}
    """

    File.write!(signal_file, content)
    IO.puts("✅ Signal file created: #{signal_file}")

    # Show that we're alive
    IO.puts("✅ Daemon is running in background")
    IO.puts("   Press Ctrl+C to stop (or kill the process)\n")

    # Keep alive indicator
    schedule_alive_check()
    {:ok, self()}
  end

  defp run_test_daemon(args) do
    # Test mode: demonstrate daemon capabilities
    IO.puts("🧪 Running daemon tests...\n")

    # Test 1: File creation
    test_file = "test_d"
    File.write!(test_file, "TEST_PASSED\nargs: #{inspect(args)}")
    IO.puts("✅ Test 1: File creation")

    # Test 2: Process info
    info = %{
      pid: :os.getpid(),
      uptime_ms: :erlang.system_time(:millisecond),
      memory: length(:erlang.memory())
    }

    File.write!(test_file, "\ninfo: #{inspect(info)}", [:append])
    IO.puts("✅ Test 2: Process info collected")

    # Test 3: Background task
    Task.start(fn ->
      Process.sleep(1000)
      File.write!(test_file, "\nbackground_task: completed", [:append])
    end)

    IO.puts("✅ Test 3: Background task started")
    IO.puts("\n📊 Results written to: #{test_file}")
    IO.puts("\n✅ All daemon tests passed!")

    schedule_alive_check()
    {:ok, self()}
  end

  defp run_custom_daemon(args) do
    # Custom configuration mode
    config = parse_args(args)

    IO.puts("⚙️  Daemon configuration:")
    Enum.each(config, fn {key, value} ->
      IO.puts("   #{key}: #{value}")
    end)

    # Create custom signal file
    signal_file = config[:signal_file] || "daemon_custom.txt"
    content = """
    DAEMON_CUSTOM
    config: #{inspect(config)}
    timestamp: #{System.system_time(:second)}
    """

    File.write!(signal_file, content)
    IO.puts("\n✅ Custom daemon started: #{signal_file}")

    schedule_alive_check()
    {:ok, self()}
  end

  defp parse_args(args) do
    Enum.reduce(args, %{signal_file: "daemon_custom.txt"}, fn arg, acc ->
      case String.split(arg, "=", parts: 2) do
        ["signal_file", value] -> %{acc | signal_file: value}
        _ -> acc
      end
    end)
  end

  defp schedule_alive_check do
    # Schedule periodic alive check (every 10 seconds)
    Process.send_after(self(), :alive_check, 10_000)
  end

  @impl true
  def handle_info(:alive_check, state) do
    # Write alive timestamp
    File.write!("daemon_heartbeat.txt", "#{System.system_time(:second)}\n", [:append])
    schedule_alive_check()
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end
end

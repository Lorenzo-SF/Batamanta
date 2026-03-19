defmodule TestDaemon do
  @moduledoc """
  Smoke test Daemon application.

  This application demonstrates proper daemon behavior:
  - Runs in background without terminal I/O
  - Creates signal file to prove it's running
  - Handles arguments for configuration
  - Stays alive until killed
  """
  use Application

  @behaviour :gen_server

  @impl true
  def start(_type, _args) do
    # Get raw arguments
    args =
      :init.get_plain_arguments()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == "--"))

    # 🔴 CRÍTICO: En modo daemon, NUNCA hacemos cleanup del directorio temporal
    # porque Erlang vive en background

    IO.puts("\n🚀 BATAMANTA DAEMON SMOKE TEST\n")

    # Show system info
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

    # 🔴 CRÍTICO: Daemon nunca termina, se queda en espera infinita
    # El proceso padre (dispenser Rust) ya retornó con éxito
    Process.sleep(:infinity)
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
    test_file = "daemon_test_result.txt"
    File.write!(test_file, "TEST_PASSED\nargs: #{inspect(args)}")
    IO.puts("✅ Test 1: File creation")

    # Test 2: Process info
    info = %{
      pid: :os.getpid(),
      uptime: :erlang.system_info(:wall_clock),
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

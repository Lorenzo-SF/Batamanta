defmodule Batamanta.DaemonIdentityTest do
  @moduledoc """
  The compatibility tuple that decides whether two packaged binaries may
  share a warm BEAM.

  Regression cover for the collision this redesign exists to prevent:
  two builds of the same app + version + target that differ only in their
  bundled ERTS used to share one socket, answered every request with
  `hash_mismatch`, recycled the daemon, and so delivered zero benefit at
  full cost — 30s per invocation in the case that surfaced it.
  """
  use ExUnit.Case, async: true

  alias Batamanta.Daemon

  @base %{
    app: "alaja",
    version: "3.1.2",
    target: "x86_64-unknown-linux-gnu",
    format: "release",
    exec_mode: "cli",
    erts: "16.4",
    cli_module: "Alaja.CLI"
  }

  describe "generated .app file" do
    @cfg %Batamanta.DaemonConfig{
      enabled: true,
      var: "X_BEAM_ALIVE",
      default_ms: 1000,
      user_app: "alaja",
      request_timeout_ms: 1000
    }

    defp consult_app do
      path =
        Path.join(System.tmp_dir!(), "batamanta_daemon_#{System.unique_integer([:positive])}.app")

      File.write!(path, Daemon.app_file_content(@cfg))
      on_exit(fn -> File.rm(path) end)
      assert {:ok, [{:application, _name, props}]} = :file.consult(String.to_charlist(path))
      {path, props}
    end

    test "declares a callback module, or ensure_all_started starts nothing" do
      {_path, props} = consult_app()

      assert Keyword.get(props, :mod) == {:batamanta_daemon_app, []},
             """
             the .app has no {mod, ...} entry, so OTP has no callback to run: \
             ensure_all_started/1 returns {:ok, [:batamanta_daemon]} while starting \
             no supervisor and binding no socket, and the wrapper waits out its \
             full 30s bind timeout on every invocation.
             """
    end

    test "is a term OTP can actually parse" do
      path =
        Path.join(System.tmp_dir!(), "batamanta_daemon_#{System.unique_integer([:positive])}.app")

      File.write!(path, Daemon.app_file_content(@cfg))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, [{:application, :batamanta_daemon, _}]} =
               :file.consult(String.to_charlist(path))
    end

    test "does not list a phantom module named after the application" do
      {_path, props} = consult_app()

      refute :batamanta_daemon in Keyword.get(props, :modules, []),
             "there is no batamanta_daemon.erl; listing it misleads release tooling"
    end

    test "every listed module has a real source file in the daemon tree" do
      src = Path.join([:code.priv_dir(:batamanta), "daemon", "src"])
      {_path, props} = consult_app()

      for mod <- Keyword.get(props, :modules, []) do
        assert File.exists?(Path.join(src, "#{mod}.erl")),
               "#{inspect(mod)} is listed in the .app but #{mod}.erl does not exist"
      end
    end

    test "the registered names match the modules the server actually registers" do
      {_path, props} = consult_app()
      registered = Keyword.get(props, :registered, [])
      modules = Keyword.get(props, :modules, [])

      for name <- registered do
        assert name in modules, "#{inspect(name)} is registered but not in modules"
      end
    end
  end

  defp base, do: base(%{})

  defp base(overrides) when is_map(overrides) do
    Map.merge(@base, overrides)
  end

  # So call sites read as `base(erts: "16.5")`.
  defp base(overrides) when is_list(overrides), do: base(Map.new(overrides))

  describe "runtime_basename/1" do
    test "keeps app and version readable" do
      name = Daemon.runtime_basename(base())
      assert String.starts_with?(name, "alaja-3.1.2-")
    end

    test "keeps the ERTS version readable, since that is the question that gets asked" do
      assert Daemon.runtime_basename(base(erts: "16.4")) =~ "-e16.4-"
    end

    test "is stable for the same identity" do
      assert Daemon.runtime_basename(base()) == Daemon.runtime_basename(base())
    end

    test "falls back gracefully when no ERTS is known" do
      name = Daemon.runtime_basename(base(erts: ""))
      assert String.starts_with?(name, "alaja-3.1.2-")
      refute name =~ "-e-"
    end
  end

  describe "discriminators" do
    # The user's scenario: 9 packaged binaries — 3 consumers × 3 ERTS
    # versions. Every one of them must get its own socket, or they evict
    # each other on every alternate invocation.
    @discriminators [
      {:app, "otro"},
      {:version, "3.1.3"},
      {:target, "aarch64-unknown-linux-musl"},
      {:format, "escript"},
      {:exec_mode, "tui"},
      {:erts, "16.5"},
      {:cli_module, "Acho.CLI"}
    ]

    for {field, value} <- @discriminators do
      test "#{field} separates daemons" do
        a = Daemon.runtime_basename(base())
        b = Daemon.runtime_basename(base(%{unquote(field) => unquote(value)}))

        refute a == b,
               "changing #{unquote(field)} must change the runtime basename, " <>
                 "otherwise two incompatible builds share one daemon"
      end
    end

    test "every pairwise combination of a 3x3 grid is distinct" do
      consumers = [
        %{format: "release", exec_mode: "cli", cli_module: "Acho.CLI"},
        %{format: "escript", exec_mode: "tui", cli_module: "Acho.CLI"},
        %{format: "release", exec_mode: "daemon", cli_module: "Acho.Daemon"}
      ]

      ertses = ["16.4", "16.5", "17.0"]

      names =
        for consumer <- consumers, erts <- ertses do
          Daemon.runtime_basename(base(Map.merge(consumer, %{erts: erts})))
        end

      assert length(Enum.uniq(names)) == 9,
             "the 3x3 grid produced collisions: #{inspect(Enum.uniq(names))}"
    end
  end

  describe "identity/1" do
    test "is the canonical, ordered field string" do
      assert Daemon.identity(base()) ==
               "app=alaja|version=3.1.2|target=x86_64-unknown-linux-gnu|" <>
                 "format=release|exec_mode=cli|erts=16.4|cli_module=Alaja.CLI"
    end

    test "ignores unknown keys so callers can pass a broader map" do
      assert Daemon.identity(base(%{unrelated: "x"})) == Daemon.identity(base())
    end

    test "renders missing fields as empty rather than crashing" do
      assert Daemon.identity(%{app: "solo"}) ==
               "app=solo|version=|target=|format=|exec_mode=|erts=|cli_module="
    end

    test "coerces non-binary values" do
      assert Daemon.identity(%{app: :alaja, erts: 16}) =~ "app=alaja"
      assert Daemon.identity(%{app: :alaja, erts: 16}) =~ "erts=16"
    end
  end

  describe "identity_hash/1" do
    test "is 8 lowercase hex chars" do
      h = Daemon.identity_hash("anything")
      assert String.length(h) == 8
      assert h =~ ~r/^[0-9a-f]{8}$/
    end

    test "differs for different inputs" do
      refute Daemon.identity_hash("a") == Daemon.identity_hash("b")
    end
  end

  describe "sun_path budget" do
    test "basename leaves room for a realistic $XDG_RUNTIME_DIR inside the 108-byte cap" do
      # AF_UNIX paths are capped at 108 bytes on Linux. The socket adds
      # 5 (".sock"), the directory 22 ("/run/user/1000/batamanta/").
      worst =
        Daemon.runtime_basename(%{
          app: "a" <> String.duplicate("b", 20),
          version: "1.0.0-rc.1",
          erts: "16.4"
        })

      total = byte_size("/run/user/1000/batamanta/") + byte_size(worst) + byte_size(".sock") + 1
      assert total <= 108, "socket path would overflow sun_path: #{total} bytes"
    end
  end
end

defmodule Batamanta.RustTemplate do
  @moduledoc """
  Manages the Rust dispenser template and compilation.

  Handles copying the template, injecting the compressed payload,
  and invoking Cargo to build the final binary.

  - Linux: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu
  - Linux musl: x86_64-unknown-linux-musl, aarch64-unknown-linux-musl
  - macOS: x86_64-apple-darwin, aarch64-apple-darwin
  - Windows: x86_64-pc-windows-msvc (dispenser shells out to Git Bash +
    the .run script; boots exclusively from the bundled ERTS, daemon
    mode falls back to legacy single-shot)
  """

  alias Batamanta.Daemon
  alias Batamanta.DaemonConfig

  @doc """
  Initializes a temporary directory with the Rust dispenser template.
  """
  @spec initialize_dispenser(Path.t()) :: :ok | {:error, File.posix()}
  def initialize_dispenser(dest_dir) do
    template_dir = Path.join(:code.priv_dir(:batamanta), "rust_template")

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _} <- File.cp_r(template_dir, dest_dir) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Injects the payload into the Rust template and builds the binary.

    - `payload_path` - Path to the compressed payload tarball
    - `binary_name` - Name for the final executable
    - `target_triple` - Rust target triple (e.g., "x86_64-unknown-linux-musl")
    - `config` - Mix project configuration
    - `format` - Output format (`:release` or `:escript`)
    - `meta` - Build metadata from the packager; must carry
      `:erts_version` so the daemon identity can tell two builds of the
      same app apart when they differ only in ERTS. Defaults to `""`.

    - `:ok` - Success
    - `{:error, reason}` - Failure
  """
  @spec build(Path.t(), String.t(), String.t(), keyword(), :release | :escript, map()) ::
          :ok | {:error, String.t()}
  def build(payload_path, binary_name, target_triple, config, format \\ :release, meta \\ %{}) do
    template_dir = Path.join(:code.priv_dir(:batamanta), "rust_template")
    build_dir = Path.join(System.tmp_dir!(), "bat_build_#{:os.system_time(:millisecond)}")

    cargo_target_dir = Path.join(System.tmp_dir!(), "bat_cargo_cache")

    File.mkdir_p!(build_dir)
    File.cp_r!(template_dir, build_dir)
    File.rm_rf!(Path.join(build_dir, "target"))

    dest_payload = Path.join([build_dir, "src", "payload.tar.zst"])

    result =
      with :ok <- copy_payload(payload_path, dest_payload),
           :ok <-
             compile_rust(
               build_dir,
               target_triple,
               config,
               cargo_target_dir,
               format,
               meta
             ) do
        copy_binary(cargo_target_dir, binary_name, target_triple)
      end

    File.rm_rf!(build_dir)
    result
  end

  defp copy_payload(payload_path, dest_payload) do
    case File.cp(payload_path, dest_payload) do
      :ok -> :ok
      {:error, reason} -> {:error, "Error copying payload: #{inspect(reason)}"}
    end
  end

  defp compile_rust(build_dir, target_triple, config, cargo_target_dir, format, meta) do
    cmd = resolve_compiler(target_triple)

    bata_config = Keyword.get(config, :batamanta, [])
    mode_str = Atom.to_string(Keyword.get(bata_config, :execution_mode, :cli))
    app_name_str = to_string(Keyword.get(config, :app, "app"))
    format_str = Atom.to_string(format)
    app_version_str = to_string(Keyword.get(config, :version, "0.0.0"))
    # target_triple arrives as a string ("x86_64-unknown-linux-gnu") from
    # the CLI option parser — Atom.to_string would crash with
    # "1st argument: not an atom" in OTP 25+.
    target_str = to_string(target_triple)

    daemon_config =
      Keyword.get(bata_config, :daemon)
      |> DaemonConfig.from_config()
      |> DaemonConfig.with_resolved_user_app()

    current_env = System.get_env() |> Enum.map(fn {k, v} -> {k, v} end)

    # Compute the build hash from the payload that's about to be embedded
    # in the binary. The wrapper will pass this hash to the daemon on
    # every request; if the daemon's baked hash differs (deploy happened),
    # the daemon self-shuts so the next client spawns a fresh one.
    payload_dest = Path.join([build_dir, "src", "payload.tar.zst"])
    build_hash = Daemon.build_hash_for(payload_dest)

    # Identity is the FULL compatibility tuple, not just the build hash.
    # Two builds that differ only in ERTS, format, exec mode or CLI module
    # must not share a daemon: the hash would catch the mismatch, but
    # only after connecting, so they would evict each other on every
    # alternate invocation and the feature would cost full price for no
    # benefit. Distinct identities get distinct sockets and never meet.
    cli_module = DaemonConfig.cli_module_default(daemon_config)

    identity_attrs = %{
      app: app_name_str,
      version: app_version_str,
      target: target_str,
      format: format_str,
      exec_mode: mode_str,
      erts: Map.get(meta, :erts_version, ""),
      cli_module: cli_module
    }

    base_env = [
      {"BATAMANTA_EXEC_MODE", mode_str},
      {"BATAMANTA_APP_NAME", app_name_str},
      {"BATAMANTA_APP_VERSION", app_version_str},
      {"BATAMANTA_TARGET", target_str},
      {"BATAMANTA_FORMAT", format_str},
      {"BATAMANTA_DAEMON_IDENTITY", Daemon.identity(identity_attrs)},
      {"BATAMANTA_DAEMON_BASENAME", Daemon.runtime_basename(identity_attrs)},
      {"CARGO_TARGET_DIR", cargo_target_dir}
    ]

    daemon_env =
      if DaemonConfig.enabled?(daemon_config) do
        daemon_config
        |> DaemonConfig.to_env_vars()
        |> Kernel.++([
          {"BATAMANTA_DAEMON_BUILD_HASH", build_hash},
          {"BATAMANTA_DAEMON_CLI_MODULE", cli_module},
          {"BATAMANTA_DAEMON_FOREGROUND", Enum.join(daemon_config.foreground, ",")}
        ])
      else
        DaemonConfig.to_env_vars(daemon_config)
      end

    env = current_env ++ base_env ++ daemon_env

    case System.cmd(cmd, ["build", "--release", "--target", target_triple],
           cd: build_dir,
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        {:error, "Rust compilation failed for #{target_triple}. Logs:\n#{output}"}
    end
  end

  defp resolve_compiler(_target_triple) do
    "cargo"
  end

  defp copy_binary(cargo_target_dir, binary_name, target_triple) do
    base_bin = Path.join([cargo_target_dir, target_triple, "release", "batamanta_dispenser"])

    compiled_bin =
      if String.contains?(target_triple, "windows"), do: base_bin <> ".exe", else: base_bin

    if File.exists?(binary_name), do: File.rm!(binary_name)

    with :ok <- File.cp(compiled_bin, binary_name),
         :ok <- File.chmod(binary_name, 0o755) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "Error copying compiled binary (from #{compiled_bin} to #{binary_name}): #{inspect(reason)}"}
    end
  end
end

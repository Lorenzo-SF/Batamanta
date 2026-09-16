defmodule Batamanta.Daemon do
  @moduledoc """
  Compiles the Erlang source of the BEAM daemon into `.beam`
  files and embeds them under `<staging>/lib/batamanta_daemon-0.1.0/ebin/`.

  The daemon is the persistent BEAM that stays alive between wrapper
  invocations. It listens on a Unix-domain socket inside the per-binary
  extraction directory and forwards each request to the user's app.

  ## Why `erlc` and not `elixirc`

  The ERTS tarballs distributed by Hex.pm and GitHub releases contain `erlc`
  (Erlang compiler) but **not** `elixirc` (Elixir compiler). The daemon
  source tree is Erlang-only, so `erlc` is sufficient and avoids requiring
  an Elixir toolchain in the runtime image.

  See RFC-0008 §"Módulos a crear/modificar" (rfcs/0008-beam-alive-mode.md).
  """

  alias Batamanta.DaemonConfig

  @daemon_vsn "0.1.0"
  @daemon_app :batamanta_daemon

  @doc """
  Compiles the daemon `.erl` sources into the given staging directory.

  ## Parameters

    * `staging_dir` — payload staging root (release `_build/prod/rel/<app>`
      or the escript temp dir). The .beam files land at
      `<staging_dir>/lib/batamanta_daemon-#{@daemon_vsn}/ebin/`.
    * `erts_path` — extracted ERTS root (must contain `bin/erlc`).
    * `daemon_config` — `%Batamanta.DaemonConfig{}` (validated).

  ## Returns

    * `:ok` — compiled (or already up-to-date, see `:force` opt)
    * `{:error, reason}` — compilation failed
  """
  @spec compile(Path.t(), Path.t(), DaemonConfig.t(), keyword()) ::
          :ok | {:error, String.t()}
  def compile(staging_dir, erts_path, daemon_config, opts \\ []) do
    with {:ok, erlc} <- find_erlc(erts_path),
         :ok <- validate_user_app(daemon_config),
         {:ok, ebin_dir} <- ensure_daemon_app_dir(staging_dir),
         :ok <- maybe_skip_if_present(opts, ebin_dir),
         {:ok, src_files} <- list_source_files(),
         :ok <- run_erlc(erlc, src_files, ebin_dir),
         :ok <- write_app_file(ebin_dir, daemon_config) do
      :ok
    end
  end

  @doc """
  Version of the embedded daemon (matches the OTP app vsn).
  """
  @spec version() :: String.t()
  def version, do: @daemon_vsn

  @doc """
  Computes a stable 12-hex-char build hash from a payload file.

  Two binaries with the same payload produce the same hash; a rebuild
  with different dependencies or a different user-app version produces a
  different hash, so a wrapper can detect "daemon is stale, deploy
  happened" and recycle it.

  The hash is the first 6 bytes of SHA-256 (in hex = 12 chars), matching
  the convention of Git short SHAs. Truncating keeps the env var and
  protocol field compact while still being 48-bit collision-resistant
  (acceptable for "did the build change?" semantics).

  Returns `""` if the file is missing (defensive: lets the daemon start
  with no hash check rather than refuse to boot).
  """
  @spec build_hash_for(Path.t()) :: String.t()
  def build_hash_for(path) do
    case File.read(path) do
      {:ok, bin} ->
        # File.read can return iodata-shaped binaries on some platforms
        # (particularly for short files). Normalise to a plain binary
        # before slicing so binary_part/3 always receives the right shape.
        plain = IO.iodata_to_binary(bin)

        :crypto.hash(:sha256, plain)
        |> binary_part(0, 6)
        |> Base.encode16(case: :lower)

      {:error, _} ->
        ""
    end
  end

  # ============================================================================
  # Internals
  # ============================================================================

  defp validate_user_app(%DaemonConfig{user_app: app}) when is_binary(app) and byte_size(app) > 0,
    do: :ok

  defp validate_user_app(_),
    do:
      {:error,
       "DaemonConfig.user_app must be resolved before compile/4 (call with_resolved_user_app/1)"}

  defp find_erlc(erts_path) do
    candidate = Path.join([erts_path, "bin", "erlc"])

    if File.exists?(candidate) do
      {:ok, candidate}
    else
      {:error,
       "erlc not found at #{candidate}. The bundled ERTS must include the Erlang compiler."}
    end
  end

  defp ensure_daemon_app_dir(staging_dir) do
    ebin_dir =
      Path.join([staging_dir, "lib", "#{@daemon_app}-#{@daemon_vsn}", "ebin"])

    case File.mkdir_p(ebin_dir) do
      :ok -> {:ok, ebin_dir}
      {:error, reason} -> {:error, "could not create #{ebin_dir}: #{inspect(reason)}"}
    end
  end

  defp maybe_skip_if_present(opts, ebin_dir) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      app_file = Path.join(ebin_dir, "#{@daemon_app}.app")

      if File.exists?(app_file) do
        # Already compiled — short-circuit so we don't pay erlc twice.
        :skip
      else
        :ok
      end
    end
  end

  defp list_source_files do
    priv_dir = :code.priv_dir(:batamanta) |> to_string()
    src_dir = Path.join([priv_dir, "daemon", "src"])

    case File.ls(src_dir) do
      {:ok, entries} ->
        erl_files =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".erl"))
          |> Enum.map(&Path.join([src_dir, &1]))
          |> Enum.sort()

        if erl_files == [] do
          {:error, "no .erl source files in #{src_dir}"}
        else
          {:ok, erl_files}
        end

      {:error, reason} ->
        {:error, "could not list #{src_dir}: #{inspect(reason)}"}
    end
  end

  defp run_erlc(erlc, src_files, out_dir) do
    args = ["-o", out_dir, "+debug_info" | src_files]

    case System.cmd(erlc, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {error, _code} ->
        {:error, "erlc failed: #{String.trim(error)}"}
    end
  end

  defp write_app_file(ebin_dir, %DaemonConfig{} = cfg) do
    app_path = Path.join(ebin_dir, "#{@daemon_app}.app")

    content = """
    {application, #{@daemon_app},
     [{description, "Batamanta BEAM daemon — keeps a BEAM alive across wrapper invocations"},
      {vsn, "#{@daemon_vsn}"},
      {registered, [batamanta_daemon_sup, batamanta_daemon_server]},
      {applications, [kernel, stdlib]},
      {env,
       [{user_app, #{inspect(cfg.user_app)}},
        {request_timeout_ms, #{cfg.request_timeout_ms}},
        {default_ttl_ms, #{cfg.default_ms}}]},
      {modules, [#{@daemon_app}, batamanta_daemon_sup, batamanta_daemon_server,
                 batamanta_daemon_protocol, batamanta_daemon_app_controller]}]}.
    """

    case File.write(app_path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{app_path}: #{inspect(reason)}"}
    end
  end
end

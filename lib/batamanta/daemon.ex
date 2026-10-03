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

  # Fields that make two daemons mutually incompatible. Order is
  # significant: it defines the canonical string, so appending is safe
  # but reordering is a breaking change for the socket naming.
  @identity_fields ~w(app version target format exec_mode erts cli_module)

  @doc """
  Canonical identity string for a packaged binary's daemon.

  Two binaries may share a daemon **only** if every field below matches.
  A daemon holds a live BEAM loaded from its own payload and dispatches
  requests to a CLI module baked at ITS startup, so anything that changes
  what that BEAM contains, or what module it will be asked to call, makes
  the pair incompatible:

    * `:app` / `:version` — which OTP app the payload carries.
    * `:target` — rust target triple, i.e. OS + arch + libc. A
      `linux-gnu` and a `linux-musl` build of the same app both run on
      one machine and must not share.
    * `:format` — `:release` vs `:escript` shape the payload differently.
    * `:exec_mode` — `:cli` / `:tui` / `:daemon` are different entry
      points; a `:tui` daemon must not serve a `:cli` request.
    * `:erts` — the bundled ERTS version. This is the one that bit us:
      two builds of the same app+version+target differing only in ERTS
      shared a socket, every request hit `hash_mismatch`, the daemon
      recycled, and the feature delivered zero benefit at full cost.
    * `:cli_module` — the module the daemon actually invokes per
      request. Read from the request (not the daemon's env) since a
      warm BEAM keeps the environment it booted with.

  The order is fixed by `@identity_fields`; unknown keys are ignored so
  callers can pass a broader map.
  """
  @spec identity(map()) :: String.t()
  def identity(attrs) when is_map(attrs) do
    Enum.map_join(@identity_fields, "|", fn field ->
      "#{field}=#{attrs |> Map.get(String.to_atom(field), "") |> to_string()}"
    end)
  end

  @doc """
  Short, stable digest of an identity string: 8 lowercase hex chars.

  Used to keep the AF_UNIX socket path inside `sun_path`'s 108-byte
  limit while still being unique per identity.
  """
  @spec identity_hash(String.t()) :: String.t()
  def identity_hash(identity) when is_binary(identity) do
    :sha256 |> :crypto.hash(identity) |> binary_part(0, 4) |> Base.encode16(case: :lower)
  end

  @doc """
  Basename (no directory, no extension) for the daemon's runtime files.

  Deliberately short, because an AF_UNIX socket path is capped at 108
  bytes and `$XDG_RUNTIME_DIR` is not ours to control. The ERTS version
  is kept readable because "which ERTS is this daemon?" is the question
  that actually comes up when several builds coexist; everything else is
  folded into the digest.

      iex> Batamanta.Daemon.runtime_basename(%{app: "alaja", version: "3.1.2", erts: "16.4", ...})
      "alaja-3.1.2-e16.4-1a2b3c4d"
  """
  @spec runtime_basename(map()) :: String.t()
  def runtime_basename(attrs) when is_map(attrs) do
    app = Map.get(attrs, :app, "app") |> to_string()
    version = Map.get(attrs, :version, "0.0.0") |> to_string()
    erts = Map.get(attrs, :erts, "") |> to_string()

    base = "#{app}-#{version}"
    base = if erts == "", do: base, else: "#{base}-e#{erts}"

    base <> "-" <> identity_hash(identity(attrs))
  end

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
         {:ok, src_files} <- list_source_files() do
      compile_sources(erlc, src_files, ebin_dir, daemon_config)
    end
  end

  defp compile_sources(erlc, src_files, ebin_dir, daemon_config) do
    case run_erlc(erlc, src_files, ebin_dir) do
      :ok -> write_app_file(ebin_dir, daemon_config)
      {:error, _} = err -> err
    end
  end

  @doc """
  Version of the embedded daemon (matches the OTP app vsn).
  """
  @spec version() :: String.t()
  def version, do: @daemon_vsn

  @doc """
  Compiles the daemon into the project's standard build path so that
  `mix release` (run AFTER this call) picks it up as a regular OTP app.

  This is the entry point used by `mix batamanta` BEFORE invoking
  `mix release`. The .beam files land at:

      <build_path>/lib/batamanta_daemon-#{@daemon_vsn}/ebin/

  Which mirrors the layout that `mix deps.compile` would produce for any
  Hex-installed dependency. After `mix release` runs, the daemon .app
  file is part of the release's lib/ tree and gets listed in
  `releases/<vsn>/start_erl.data`'s application list automatically.

  `build_path` typically resolves to `Mix.Project.build_path()/2` for
  `MIX_ENV=prod`, i.e. `_build/prod/`.

  ## Parameters

    * `build_path` — Mix build root (e.g. `_build/prod`).
    * `erts_path` — extracted ERTS root (must contain `bin/erlc`).
    * `daemon_config` — `%Batamanta.DaemonConfig{}` (validated).

  ## Returns

    * `:ok` — compiled (or already up-to-date)
    * `{:error, reason}` — compilation failed
  """
  @spec compile_to_build_path(Path.t(), Path.t(), DaemonConfig.t(), keyword()) ::
          :ok | {:error, String.t()}
  def compile_to_build_path(build_path, erts_path, daemon_config, opts \\ []) do
    # `build_path` is passed through verbatim: `compile/4`'s `staging_dir`
    # IS the root that `ensure_daemon_app_dir/1` appends `lib/`, the app
    # dir and `ebin/` to. Appending a second `lib` here landed the daemon
    # at `_build/prod/lib/lib/batamanta_daemon-<vsn>/ebin`, which
    # `mix release` does not scan — so the release shipped without the
    # daemon app, the bootstrap eval died with `undefined variable
    # "batamanta_daemon"`, and every invocation burned 30s waiting for a
    # socket that could never be bound before falling back to a cold
    # start.
    compile(build_path, erts_path, daemon_config, opts)
  end

  @doc """
  Contents of the generated `batamanta_daemon.app`.

  Split out of the writer so the `.app` contract can be asserted without
  an `erlc` and a full compile in the way.

  The `{mod, ...}` entry is load-bearing. Without it the `.app` declares
  an OTP application with no callback module, so
  `Application.ensure_all_started(:batamanta_daemon)` answers
  `{:ok, [:batamanta_daemon]}` while starting nothing at all: no
  supervisor, no socket. The wrapper then sits out its full 30s bind
  timeout on every invocation and falls back to a cold start — which is
  exactly the symptom this whole bootstrap chain was being blamed on.

  `modules` lists only real `.beam` files. It used to lead with the
  application name as if it were a module (`batamanta_daemon`), which does
  not exist; harmless to the VM, but it makes release tooling report a
  phantom module and misleads anyone reading the `.app` to debug a boot
  problem.
  """
  @spec app_file_content(DaemonConfig.t()) :: String.t()
  def app_file_content(%DaemonConfig{} = cfg) do
    """
    {application, #{@daemon_app},
     [{description, "Batamanta BEAM daemon — keeps a BEAM alive across wrapper invocations"},
      {vsn, "#{@daemon_vsn}"},
      {mod, {batamanta_daemon_app, []}},
      {registered, [batamanta_daemon_sup, batamanta_daemon_server]},
      {applications, [kernel, stdlib]},
      {env,
       [{user_app, #{inspect(cfg.user_app)}},
        {request_timeout_ms, #{cfg.request_timeout_ms}},
        {default_ttl_ms, #{cfg.default_ms}}]},
      {modules, [batamanta_daemon_app, batamanta_daemon_sup, batamanta_daemon_server,
                 batamanta_daemon_protocol, batamanta_daemon_app_controller]}]}.
    """
  end

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
    ebin_dir = Path.join([staging_dir, "lib", "#{@daemon_app}-#{@daemon_vsn}", "ebin"])

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

      if File.exists?(app_file) and not sources_newer_than?(ebin_dir) do
        # Already compiled AND the sources have not changed since — short
        # -circuit so we don't pay erlc twice.
        :skip
      else
        :ok
      end
    end
  end

  # True when any .erl or .hrl in the daemon tree is newer than the
  # compiled .app.
  #
  # Keying the skip purely on "the .app exists" meant that editing a
  # daemon source and re-running `mix batamanta` silently kept the OLD
  # .beam files: the build reported success, the payload carried stale
  # code, and the fix you just wrote appeared not to work. That is a very
  # expensive trap when the thing being debugged is a packaging step, so
  # freshness is part of the decision rather than a manual `rm -rf`.
  @spec sources_newer_than?(Path.t()) :: boolean()
  defp sources_newer_than?(ebin_dir) do
    priv_dir = :code.priv_dir(:batamanta) |> to_string()
    src_dir = Path.join([priv_dir, "daemon", "src"])

    case File.ls(src_dir) do
      {:ok, entries} ->
        compiled_at = mtime(app_path_in(ebin_dir))

        entries
        |> Enum.filter(&(String.ends_with?(&1, ".erl") or String.ends_with?(&1, ".hrl")))
        |> Enum.map(&mtime(Path.join(src_dir, &1)))
        |> Enum.any?(&(is_integer(&1) and (not is_integer(compiled_at) or &1 > compiled_at)))

      _ ->
        false
    end
  end

  defp app_path_in(ebin_dir), do: Path.join(ebin_dir, "#{@daemon_app}.app")

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
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

    case File.write(app_path, app_file_content(cfg)) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{app_path}: #{inspect(reason)}"}
    end
  end
end

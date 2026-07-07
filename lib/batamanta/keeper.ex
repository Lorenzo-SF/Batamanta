defmodule Batamanta.Keeper do
  @moduledoc """
  Compila el código fuente del keeper (`priv/keeper/src/*.erl`) en `.beam`
  usando el `erlc` que viene con el ERTS bundled en el payload.

  El resultado se deposita en `<staging>/lib/batamanta_keeper-0.1.0/ebin/`,
  de modo que cuando se incluya ese staging dir en el `code:add_pathsa/1`
  del wrapper Rust, el keeper BEAM pueda arrancar.

  ## Uso

      iex> Batamanta.Keeper.compile("/tmp/rel", "/path/to/erts-14.2")
      :ok

      iex> Batamanta.Keeper.compile("/tmp/rel", "/path/to/erts-14.2")
      {:error, "erlc not found at ..."}

  ## Fase 2: stubs

  Por ahora el código generado contiene solo stubs. En Phase 4 el
  `batamanta_keeper_server.erl` será real y escuchará en el Unix socket.

  ## Por qué `erlc` y no `elixirc`

  Los tarballs de ERTS que Batamanta descarga de Hex.pm son **OTP-only**:
  contienen `erlc` (compilador de Erlang) pero no `elixirc` (compilador de
  Elixir). Como los .erl del keeper son Erlang puro, `erlc` es suficiente
  y no requiere un toolchain Elixir en el runtime.

  See RFC-0008 (rfcs/0008-beam-alive-mode.md) §"Módulos a crear/modificar".
  """

  @keeper_vsn "0.1.0"
  @keeper_app :batamanta_keeper

  @doc """
  Compila los `.erl` del keeper contra el ERTS dado.

  `staging_dir` es el directorio de empaquetado del release (o del
  escript), donde se depositarán `lib/#{@keeper_app}-#{@keeper_vsn}/ebin/`.

  `erts_path` es el path al ERTS bundlado (cache descargado o unpacked).
  Se usa `erts_path/bin/erlc` como compilador.

  Opciones:
    * `:force` — recompila aunque los .beam estén ya en su sitio (default: false)

  Returns:
    * `:ok` si compiló bien (o si los .beam ya existían y `force: false`)
    * `{:error, reason}` si falló la compilación
  """
  @spec compile(Path.t(), Path.t(), keyword()) :: :ok | {:error, String.t()}
  def compile(staging_dir, erts_path, opts \\ []) do
    with {:ok, erlc} <- find_erlc(erts_path),
         {:ok, keeper_app_dir} <- ensure_keeper_app_dir(staging_dir),
         :ok <- maybe_skip_if_present(opts, keeper_app_dir),
         {:ok, src_files} <- list_source_files(),
         :ok <- run_erlc(erlc, src_files, keeper_app_dir),
         :ok <- write_app_file(keeper_app_dir) do
      :ok
    end
  end

  @doc """
  Versión del keeper embebido. Útil para diagnóstico.
  """
  @spec version() :: String.t()
  def version, do: @keeper_vsn

  # ============================================================================
  # Internals
  # ============================================================================

  defp find_erlc(erts_path) do
    candidate = Path.join([erts_path, "bin", "erlc"])

    if File.exists?(candidate) do
      {:ok, candidate}
    else
      {:error, "erlc not found at #{candidate}. ERTS must include the Erlang compiler."}
    end
  end

  defp ensure_keeper_app_dir(staging_dir) do
    ebin_dir =
      Path.join([staging_dir, "lib", "#{@keeper_app}-#{@keeper_vsn}", "ebin"])

    case File.mkdir_p(ebin_dir) do
      :ok -> {:ok, ebin_dir}
      {:error, reason} -> {:error, "could not create #{ebin_dir}: #{inspect(reason)}"}
    end
  end

  defp maybe_skip_if_present(opts, ebin_dir) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      app_file = Path.join(ebin_dir, "#{@keeper_app}.app")

      if File.exists?(app_file) do
        # Already compiled — return a skip marker so the rest of the
        # pipeline doesn't run erlc twice.
        :skip
      else
        :ok
      end
    end
  end

  defp list_source_files do
    priv_dir = :code.priv_dir(:batamanta) |> to_string()
    src_dir = Path.join([priv_dir, "keeper", "src"])

    case File.ls(src_dir) do
      {:ok, entries} ->
        erl_files =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".erl"))
          |> Enum.map(&Path.join([src_dir, &1]))

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

  defp write_app_file(ebin_dir) do
    app_path = Path.join(ebin_dir, "#{@keeper_app}.app")

    content = """
    {application, #{@keeper_app},
     [{description, "Batamanta BEAM alive mode keeper (Phase 2 stub)"},
      {vsn, "#{@keeper_vsn}"},
      {registered, [batamanta_keeper_sup, batamanta_keeper_server]},
      {applications, [kernel, stdlib]},
      {env, []},
      {modules, [#{@keeper_app}, batamanta_keeper_sup, batamanta_keeper_server,
                 batamanta_keeper_protocol, batamanta_keeper_runner]}]}.
    """

    case File.write(app_path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{app_path}: #{inspect(reason)}"}
    end
  end
end

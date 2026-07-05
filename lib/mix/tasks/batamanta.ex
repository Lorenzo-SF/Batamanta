defmodule Mix.Tasks.Batamanta do
  @moduledoc """
  Main Mix task to generate the monolithic binary.

  This task orchestrates the fetching of ERTS, packaging of the release/escript,
  and compilation of the Rust wrapper.


  Batamanta supports two output formats:
  - `:release` (default) - Full OTP release with supervisor tree
  - `:escript` - Lightweight escript with embedded Elixir runtime

  For projects using `mix escript.build`, use:

      batamanta: [
        format: :escript
      ]


  ## Umbrella Projects

  Set `umbrella: true` at the umbrella root to package only the sub-apps
  that have `batamanta:` configured in their individual `mix.exs`:

      # umbrella_root/mix.exs
      batamanta: [
        umbrella: true
      ]

      # umbrella_root/apps/my_app/mix.exs
      batamanta: [
        format: :release
      ]

  Each sub-app is packaged independently using its own config. The umbrella
  root config provides shared settings (ERTS target, OTP version) while each
  sub-app can override `format`, `binary_name`, `compression`, and `execution_mode`.


  **User specifies, user owns.** If you specify `otp_version`, that exact version
  is used. If not specified (auto mode), a conservative fallback is used.

      batamanta: [
      ]

  In auto mode (no version specified), the system tries:
  - 28.0 → 28.1 → 28.2 → ... (fallback to first available)


  Batamanta handles its own garbage. After each successful compilation, it:
  - **Removes** `bat_cargo_cache` from the system temp directory
  - **Deletes** `bat_pkg_*` and `bat_build_*` intermediate folders
  - **Preserves** the ERTS cache (`~/.cache/batamanta`) for sub-second repeat builds

  To manually wipe the entire cache (including downloaded ERTS), use `mix batamanta.clean`.

  Use `:erts_target` for unified platform specification:

      batamanta: [
        execution_mode: :cli,
        compression: 3,
      ]


  | Target Atom | Description |
  |-------------|-------------|
  | `:auto` | Auto-detect host platform (default) |
  | `:ubuntu_22_04_x86_64` | Linux x86_64 glibc (Debian, Ubuntu, Arch, CachyOS) |
  | `:ubuntu_22_04_arm64` | Linux aarch64 glibc |
  | `:alpine_3_19_x86_64` | Linux x86_64 musl (Alpine) |
  | `:alpine_3_19_arm64` | Linux aarch64 musl |
  | `:macos_12_x86_64` | macOS Intel |
  | `:macos_12_arm64` | macOS Apple Silicon |
   | `:windows_x86_64` | Windows x86_64 |


  Force specific platform regardless of host:

      batamanta: [
        force_arch: "x86_64",
        force_libc: "musl",
      ]


  You can force the binary name by setting `:binary_name` in the config:

      batamanta: [
        binary_name: "my_custom_binary"
      ]

      mix batamanta

  - `--erts-target` - Override ERTS target atom
  - `--otp-version` - Specify exact OTP version (e.g., "28.1")
  - `--force-os` - Force OS (linux, macos, windows)
  - `--force-arch` - Force architecture (x86_64, aarch64)
  - `--force-libc` - Force libc (gnu, musl) - Linux only
  - `--compression` - Zstd compression level (1-19)
  - `--format` - Output format: escript or release (default: release)
  """
  use Mix.Task

  alias Batamanta.Banner
  alias Batamanta.EnvCleaner
  alias Batamanta.ERTS
  alias Batamanta.EscriptBuilder
  alias Batamanta.EscriptPackager
  alias Batamanta.Logger
  alias Batamanta.Packager
  alias Batamanta.RustTemplate
  alias Batamanta.Target
  alias Batamanta.Validator

  @shortdoc "Generates a monolithic binary"

  @impl Mix.Task
  def run(args) do
    validate_toolchain!()

    cleanup_stale_temporaries()

    opts = parse_options(args)
    config = Mix.Project.config()
    bata_config = Keyword.get(config, :batamanta, [])

    umbrella = Keyword.get(bata_config, :umbrella, false)

    if umbrella do
      run_umbrella(opts, config, bata_config)
    else
      run_single(opts, config, bata_config)
    end
  end

  defp run_single(opts, config, bata_config) do
    format = resolve_format(opts, bata_config, config)

    erts_target = resolve_erts_target(opts, bata_config)
    override_config = build_override_config(opts, bata_config)
    binary_name = override_config.binary_name

    {:ok, resolved_target} = Target.resolve_auto(erts_target, override_config)
    target_info = Target.get_target_info(resolved_target)

    {otp_version, version_mode} = resolve_otp_version(opts, bata_config)

    show_banner = Keyword.get(bata_config, :show_banner, true)

    banner_ctx =
      build_banner(otp_version, target_info, resolved_target, show_banner, version_mode, format)

    execution_mode = Keyword.get(bata_config, :execution_mode, :cli)
    Validator.validate!(os: target_info.os, arch: target_info.arch, mode: execution_mode)

    if target_info.os == "linux" do
      Target.validate_libc!(resolved_target)
    end

    compression = opts[:compression] || bata_config[:compression] || 3

    with {:ok, erts_path} <-
           fetch_erts({otp_version, version_mode}, resolved_target, target_info, banner_ctx) do
      execute_pipeline(
        config,
        resolved_target,
        target_info,
        erts_path,
        compression,
        binary_name,
        banner_ctx,
        format
      )
    end
  end

  defp run_umbrella(opts, config, bata_config) do
    apps = find_umbrella_apps(config)

    if apps == [] do
      Mix.shell().info("[batamanta] no umbrella apps with batamanta config found")
      :ok
    else
      run_umbrella_with_apps(apps, opts, config, bata_config)
    end
  end

  defp run_umbrella_with_apps(apps, opts, config, bata_config) do
    show_banner = Keyword.get(bata_config, :show_banner, true)

    erts_target = resolve_erts_target(opts, bata_config)
    override_config = build_override_config(opts, bata_config)
    {:ok, resolved_target} = Target.resolve_auto(erts_target, override_config)
    target_info = Target.get_target_info(resolved_target)

    {otp_version, version_mode} = resolve_otp_version(opts, bata_config)

    banner_ctx =
      build_umbrella_banner(
        otp_version,
        target_info,
        resolved_target,
        show_banner,
        version_mode,
        apps
      )

    compression = opts[:compression] || bata_config[:compression] || 3

    {release_apps, escript_apps} = partition_apps_by_format(apps, opts)

    with {:ok, erts_path} <-
           fetch_erts({otp_version, version_mode}, resolved_target, target_info, banner_ctx) do
      if release_apps != [] do
        run_umbrella_release(
          release_apps,
          config,
          erts_path,
          resolved_target,
          target_info,
          compression,
          banner_ctx
        )
      end

      if escript_apps != [] do
        run_umbrella_escripts(
          escript_apps,
          erts_path,
          resolved_target,
          target_info,
          compression,
          banner_ctx
        )
      end

      Banner.set_image(banner_ctx, :success)
    end
  end

  @doc false
  def find_umbrella_apps(config) do
    apps_path = Keyword.get(config, :apps_path, "apps")
    umbrella_root = File.cwd!()
    apps_dir = Path.join(umbrella_root, apps_path)

    if File.dir?(apps_dir) do
      File.ls!(apps_dir)
      |> Enum.filter(fn entry ->
        app_path = Path.join(apps_dir, entry)
        mix_file = Path.join(app_path, "mix.exs")
        File.dir?(app_path) && File.exists?(mix_file) && app_has_batamanta_config?(app_path)
      end)
      |> Enum.map(fn entry ->
        {String.to_atom(entry), Path.join(apps_dir, entry)}
      end)
    else
      []
    end
  end

  defp app_has_batamanta_config?(app_path) do
    app_name = Path.basename(app_path) |> String.to_atom()

    try do
      Mix.Project.in_project(app_name, app_path, [], fn _module ->
        config = Mix.Project.config()
        bata_config = Keyword.get(config, :batamanta, [])
        Keyword.keyword?(bata_config) && bata_config != []
      end)
    rescue
      _ -> false
    end
  end

  @doc false
  def partition_apps_by_format(apps, opts) do
    Enum.split_with(apps, fn {app_name, app_path} ->
      try do
        Mix.Project.in_project(app_name, app_path, [], fn _module ->
          config = Mix.Project.config()
          bata_config = Keyword.get(config, :batamanta, [])
          format = resolve_format(opts, bata_config, config)
          format == :release
        end)
      rescue
        _ -> true
      end
    end)
  end

  @doc false
  def build_umbrella_banner(
        otp_version,
        target_info,
        _resolved_target,
        show_banner,
        version_mode,
        apps
      ) do
    mode_str = if version_mode == :explicit, do: " (user-specified)", else: " (auto-detected)"
    app_names = Enum.map_join(apps, ", ", fn {name, _path} -> Atom.to_string(name) end)

    messages = [
      ">> 🏠 Umbrella apps: #{app_names}",
      ">> 🖥️  OS: #{target_info.os}",
      ">> ⚙️  Architecture: #{target_info.arch}",
      ">> 📦 Type: #{target_info.libc || "N/A"}",
      ">> 🔢 ERTS: #{otp_version}#{mode_str}"
    ]

    Banner.show_with_context(messages,
      show_banner: show_banner,
      on_success_image: "batamantaman_happy.png",
      on_error_image: "batamantaman_sad.png"
    )
  end

  defp run_umbrella_release(
         apps,
         _config,
         erts_path,
         resolved_target,
         target_info,
         compression,
         banner_ctx
       ) do
    build_env =
      EnvCleaner.build_env(erts_path)
      |> Map.new()
      |> Map.put("MIX_ENV", "prod")

    # Construir el release de CADA sub-app en su propio directorio.
    # Sin `cd: app_path` se construía el release del root del umbrella
    # (que normalmente no es una release), dejando `_build/prod/rel`
    # en la sub-app sin poblar.
    Enum.each(apps, fn {app_name, app_path} ->
      Logger.info(banner_ctx, ">> 📦 Creating Release for #{app_name}...")

      {out, status} =
        System.cmd("mix", ["release", "--overwrite", "--quiet"],
          cd: app_path,
          env: build_env,
          stderr_to_stdout: true
        )

      if status != 0 do
        Logger.error(banner_ctx, "Mix release compilation failed for #{app_name}:")
        Logger.error(banner_ctx, out)
        Banner.set_image(banner_ctx, :error)
        Mix.raise("Mix release compilation failed for #{app_name}.")
      end
    end)

    Enum.each(apps, fn {app_name, app_path} ->
      try do
        {app_config, app_bata_config} = read_umbrella_app_config(app_name, app_path)
        app_binary_name = Keyword.get(app_bata_config, :binary_name)
        app_compression = app_bata_config[:compression] || compression

        # En un umbrella, el release vive en la sub-app, no en el root.
        # Pasamos app_path para que get_release_path/2 apunte al sitio
        # correcto.
        release_path = get_release_path(app_config[:app], app_path)

        if File.dir?(release_path) do
          payload_path =
            Path.join(
              System.tmp_dir!(),
              "payload_#{app_name}_#{:erlang.unique_integer([:positive])}.tar.zst"
            )

          Logger.info(
            banner_ctx,
            ">> 📦 Packaging Payload for #{app_name} (Zstd level #{app_compression})..."
          )

          case Packager.package(release_path, erts_path, payload_path, app_compression) do
            {:ok, _} ->
              compile_wrapper(
                :release,
                app_config,
                payload_path,
                resolved_target,
                target_info,
                app_binary_name,
                banner_ctx
              )

              File.rm(payload_path)

            {:error, reason} ->
              Logger.error(banner_ctx, "Packaging Error for #{app_name}: #{reason}")
              Banner.set_image(banner_ctx, :error)
          end
        else
          Logger.info(
            banner_ctx,
            ">> ⏭️  Skipping #{app_name}: release not found at #{release_path}"
          )
        end
      rescue
        e ->
          Logger.error(banner_ctx, "Error processing #{app_name}: #{Exception.message(e)}")
      end
    end)
  end

  defp run_umbrella_escripts(
         apps,
         erts_path,
         resolved_target,
         target_info,
         compression,
         banner_ctx
       ) do
    Enum.each(apps, fn {app_name, app_path} ->
      try do
        Logger.info(banner_ctx, ">> 📦 Creating Escript for #{app_name}...")

        {app_config, app_bata_config} = read_umbrella_app_config(app_name, app_path)
        app_binary_name = Keyword.get(app_bata_config, :binary_name)
        app_compression = app_bata_config[:compression] || compression
        app_exec_mode = Keyword.get(app_bata_config, :execution_mode, :cli)

        build_env = EnvCleaner.build_env(erts_path)

        {output, status} =
          System.cmd("mix", ["escript.build"],
            cd: app_path,
            env: build_env,
            stderr_to_stdout: true
          )

        if status != 0 do
          Logger.error(banner_ctx, "Escript build failed for #{app_name}:")
          Logger.error(banner_ctx, output)
          Banner.set_image(banner_ctx, :error)
        else
          escript_path = EscriptBuilder.find_escript_path(app_config)

          if File.exists?(escript_path) do
            EscriptBuilder.validate_escript!(escript_path)

            Logger.info(banner_ctx, ">> ✅ Escript built for #{app_name}: #{escript_path}")

            payload_path =
              Path.join(
                System.tmp_dir!(),
                "payload_#{app_name}_#{:erlang.unique_integer([:positive])}.tar.zst"
              )

            Logger.info(
              banner_ctx,
              ">> 📦 Packaging Escript for #{app_name} (Zstd level #{app_compression})..."
            )

            case EscriptPackager.package(escript_path, erts_path, payload_path, app_compression,
                   execution_mode: app_exec_mode
                 ) do
              {:ok, _} ->
                compile_wrapper(
                  :escript,
                  app_config,
                  payload_path,
                  resolved_target,
                  target_info,
                  app_binary_name,
                  banner_ctx
                )

                File.rm(payload_path)

              {:error, reason} ->
                Logger.error(banner_ctx, "Escript packaging error for #{app_name}: #{reason}")
                Banner.set_image(banner_ctx, :error)
            end
          else
            Logger.error(banner_ctx, "Escript not found for #{app_name}: #{escript_path}")
            Banner.set_image(banner_ctx, :error)
          end
        end
      rescue
        e ->
          Logger.error(banner_ctx, "Error processing #{app_name}: #{Exception.message(e)}")
      end
    end)
  end

  @doc false
  def read_umbrella_app_config(app_name, app_path) do
    Mix.Project.in_project(app_name, app_path, [], fn _module ->
      config = Mix.Project.config()
      bata_config = Keyword.get(config, :batamanta, [])
      {config, bata_config}
    end)
  end

  @doc """
  Resolves the output format from options, config, or auto-detection.

  Priority:
  1. CLI option `--format`
  2. Config `format:` key
  3. Auto-detect: if project has `:escript` config, use `:escript`, else `:release`
  """
  def resolve_format(opts, bata_config, project_config) do
    if format = Keyword.get(opts, :format) do
      normalized = normalize_format(format)
      validate_format!(normalized)
      normalized
    else
      if format = Keyword.get(bata_config, :format) do
        validate_format!(format)
        format
      else
        auto_detected_format(project_config)
      end
    end
  end

  defp normalize_format(format) when is_binary(format), do: String.to_atom(format)
  defp normalize_format(format) when is_atom(format), do: format

  defp auto_detected_format(config) do
    if Keyword.has_key?(config, :escript) do
      :escript
    else
      :release
    end
  end

  defp validate_format!(:escript), do: :ok
  defp validate_format!(:release), do: :ok

  defp validate_format!(other) do
    Mix.raise("Invalid format '#{inspect(other)}'. Valid formats are: :escript, :release")
  end

  @doc """
  Parses command-line options.
  """
  def parse_options(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          erts_target: :string,
          force_os: :string,
          force_arch: :string,
          force_libc: :string,
          compression: :integer,
          otp_version: :string,
          format: :string
        ]
      )

    opts
  end

  @doc """
  Resolves ERTS target from options and config.
  """
  def resolve_erts_target(opts, bata_config) do
    Keyword.get(opts, :erts_target) ||
      Keyword.get(bata_config, :erts_target) ||
      :auto
  end

  @doc """
  Builds override config from options and config.
  """
  def build_override_config(opts, bata_config) do
    %{
      force_os: Keyword.get(opts, :force_os) || Keyword.get(bata_config, :force_os),
      force_arch: Keyword.get(opts, :force_arch) || Keyword.get(bata_config, :force_arch),
      force_libc: Keyword.get(opts, :force_libc) || Keyword.get(bata_config, :force_libc),
      binary_name: Keyword.get(bata_config, :binary_name)
    }
  end

  @doc """
  Resolves OTP version from options and config.

  Returns a tuple with:
  - version string
  - mode: :explicit (user specified) or :auto (detected from system)

  - If user specifies `otp_version` in config or CLI, that exact version is used
  - If no version specified (auto mode), uses conservative fallback (tries 28.0, 28.1, etc.)
  """
  def resolve_otp_version(opts, bata_config) do
    explicit_version =
      Keyword.get(opts, :otp_version) ||
        Keyword.get(bata_config, :otp_version)

    if explicit_version do
      {explicit_version, :explicit}
    else
      {:erlang.system_info(:otp_release) |> to_string(), :auto}
    end
  end

  defp fetch_erts({otp_version, mode}, resolved_target, _target_info, banner_ctx) do
    case ERTS.Fetcher.fetch(otp_version, resolved_target, version_mode: mode) do
      {:ok, erts_path} ->
        {:ok, erts_path}

      {:error, reason} ->
        Logger.error(banner_ctx, "Failed to fetch ERTS: #{reason}")
        Mix.raise("Failed to fetch ERTS: #{reason}")
    end
  end

  defp execute_pipeline(
         config,
         erts_target,
         target_info,
         erts_path,
         compression,
         binary_name,
         banner_ctx,
         format
       ) do
    case format do
      :release ->
        execute_release_pipeline(
          config,
          erts_target,
          target_info,
          erts_path,
          compression,
          binary_name,
          banner_ctx
        )

      :escript ->
        execute_escript_pipeline(
          config,
          erts_target,
          target_info,
          erts_path,
          compression,
          binary_name,
          banner_ctx
        )
    end
  end

  defp execute_release_pipeline(
         config,
         erts_target,
         target_info,
         erts_path,
         compression,
         binary_name,
         banner_ctx
       ) do
    Logger.info(banner_ctx, ">> 📦 Creating Release...")

    build_env =
      EnvCleaner.build_env(erts_path)
      |> Map.new()
      |> Map.put("MIX_ENV", "prod")

    {out, status} =
      System.cmd("mix", ["release", "--overwrite", "--quiet"],
        env: build_env,
        stderr_to_stdout: true
      )

    if status != 0 do
      Logger.error(banner_ctx, "Mix release compilation failed:")
      Logger.error(banner_ctx, out)
      Banner.set_image(banner_ctx, :error)
      Mix.raise("Mix release compilation failed.")
    end

    payload_path =
      Path.join(System.tmp_dir!(), "payload_#{:erlang.unique_integer([:positive])}.tar.zst")

    release_path = get_release_path(config[:app])

    Logger.info(banner_ctx, ">> 📦 Packaging Payload (Zstd level #{compression})...")

    case Packager.package(release_path, erts_path, payload_path, compression) do
      {:ok, _} ->
        compile_wrapper(
          :release,
          config,
          payload_path,
          erts_target,
          target_info,
          binary_name,
          banner_ctx
        )

        File.rm(payload_path)

      {:error, reason} ->
        Banner.set_image(banner_ctx, :error)
        Mix.raise("Packaging Error: #{reason}")
    end
  end

  defp execute_escript_pipeline(
         config,
         erts_target,
         target_info,
         erts_path,
         compression,
         binary_name,
         banner_ctx
       ) do
    Logger.info(banner_ctx, ">> 📦 Creating Escript...")

    escript_path = EscriptBuilder.build(config, banner_ctx, erts_path)

    payload_path =
      Path.join(System.tmp_dir!(), "payload_#{:erlang.unique_integer([:positive])}.tar.zst")

    Logger.info(banner_ctx, ">> 📦 Packaging Escript (Zstd level #{compression})...")

    bata_config = Keyword.get(config, :batamanta, [])
    exec_mode = Keyword.get(bata_config, :execution_mode, :cli)

    case EscriptPackager.package(escript_path, erts_path, payload_path, compression,
           execution_mode: exec_mode
         ) do
      {:ok, _} ->
        compile_wrapper(
          :escript,
          config,
          payload_path,
          erts_target,
          target_info,
          binary_name,
          banner_ctx
        )

        File.rm(payload_path)

      {:error, reason} ->
        Banner.set_image(banner_ctx, :error)
        Mix.raise("Escript packaging error: #{reason}")
    end
  end

  # Calcula la ruta absoluta al release de la aplicación.
  #
  # Para proyectos normales: `<root>/_build/prod/rel/<app>`.
  # Para sub-apps de un umbrella: `<sub_app>/_build/prod/rel/<app>` —
  # el `_build` está donde se ejecutó `mix release`, no en el root del
  # umbrella. En este caso se debe pasar `app_path` para que el
  # cálculo apunte al sub-app correcto.
  #
  # Examples:
  #
  #     iex> get_release_path(:my_app)
  #     "/home/user/proj/_build/prod/rel/my_app"
  #
  #     iex> get_release_path(:my_app, "/home/user/proj/apps/my_app")
  #     "/home/user/proj/apps/my_app/_build/prod/rel/my_app"
  @spec get_release_path(atom(), String.t() | nil) :: String.t()
  def get_release_path(app, app_path \\ nil) do
    base =
      case app_path do
        nil ->
          # Proyecto normal: _build vive dos niveles por encima del
          # build_path (build_path = _build/dev → root = ../..).
          Mix.Project.build_path()
          |> Path.dirname()
          |> Path.dirname()

        path ->
          # Sub-app de umbrella: el _build está dentro del propio
          # sub-app, no en el root.
          path
      end

    Path.join([base, "_build", "prod", "rel", Atom.to_string(app)])
    |> Path.absname()
  end

  defp compile_wrapper(
         format,
         config,
         payload_path,
         erts_target,
         target_info,
         binary_name,
         banner_ctx
       ) do
    rust_target = target_info.rust_target
    binary_suffix = Target.erts_target_to_binary_suffix(erts_target)

    final_name =
      if binary_name do
        binary_name
      else
        "#{config[:app]}-#{config[:version]}-#{binary_suffix}"
      end

    Logger.info(
      banner_ctx,
      ">> 🔨 Compiling Rust Wrapper for #{target_info.os} #{target_info.arch} (#{target_info.libc || "N/A"})..."
    )

    case RustTemplate.build(payload_path, final_name, rust_target, config, format) do
      :ok ->
        apply_minify(final_name, banner_ctx)
        cleanup_temporaries(banner_ctx)
        Logger.info(banner_ctx, "✅ Process completed: #{final_name}")
        Banner.set_image(banner_ctx, :success)

      {:error, err} ->
        Banner.set_image(banner_ctx, :error)
        Mix.raise(err)
    end
  end

  defp apply_minify(name, banner_ctx) do
    case :os.type() do
      {:unix, _} ->
        Logger.info(banner_ctx, ">> ✂️  Stripping binary...")
        System.cmd("strip", [name])

      _ ->
        Logger.info(banner_ctx, ">> Skipping strip (not supported on this OS)")
    end
  end

  @doc "Validates required system tools"
  def validate_toolchain! do
    if System.find_executable("cargo") == nil, do: Mix.raise("Rust (cargo) not found.")
    if System.find_executable("zstd") == nil, do: Mix.raise("zstd not found.")
    :ok
  end

  defp build_banner(otp_version, target_info, _resolved_target, show_banner, version_mode, format) do
    mode_str = if version_mode == :explicit, do: " (user-specified)", else: " (auto-detected)"
    format_str = if format == :escript, do: " [escript]", else: ""

    messages = [
      ">> 🖥️  OS: #{target_info.os}",
      ">> ⚙️  Architecture: #{target_info.arch}",
      ">> 📦 Type: #{target_info.libc || "N/A"}",
      ">> 🔢 ERTS: #{otp_version}#{mode_str}#{format_str}"
    ]

    Banner.show_with_context(messages,
      show_banner: show_banner,
      on_success_image: "batamantaman_happy.png",
      on_error_image: "batamantaman_sad.png"
    )
  end

  defp cleanup_temporaries(_ctx) do
    cargo_target_dir = Path.join(System.tmp_dir!(), "bat_cargo_cache")

    if File.exists?(cargo_target_dir) do
      File.rm_rf(cargo_target_dir)
    end

    System.tmp_dir!()
    |> Path.join("bat_pkg_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    System.tmp_dir!()
    |> Path.join("bat_build_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    System.tmp_dir!()
    |> Path.join("batamanta_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
  end

  defp cleanup_stale_temporaries do
    temp_base = System.tmp_dir!()

    patterns = [
      "bat_pkg_*",
      "bat_build_*",
      "bat_cargo_cache",
      "batamanta_*",
      "batamanta_escript_wrapper_*"
    ]

    Enum.each(patterns, fn pattern ->
      temp_base
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.each(fn dir ->
        try do
          case File.stat(dir) do
            {:ok, %{mtime: mtime}} ->
              age_seconds = mtime_to_age_seconds(mtime)

              if age_seconds > 3600 do
                lock_path = Path.join(dir, ".batamanta_lock")

                if File.exists?(lock_path) do
                  :skip
                else
                  File.rm_rf(dir)
                end
              end

            _ ->
              :skip
          end
        rescue
          _ -> :skip
        end
      end)
    end)

    clean_mix_build_artifacts()
  end

  defp clean_mix_build_artifacts do
    project_root =
      Mix.Project.build_path()
      |> Path.dirname()
      |> Path.dirname()

    build_dir = Path.join(project_root, "_build")

    if File.dir?(build_dir) do
      ["dev", "test"]
      |> Enum.map(&Path.join(build_dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.each(&clean_if_stale/1)
    end
  end

  defp clean_if_stale(dir) do
    case File.stat(dir) do
      {:ok, %{mtime: mtime}} ->
        age_seconds = mtime_to_age_seconds(mtime)

        if age_seconds > 86_400 do
          File.rm_rf(dir)
        end

      _ ->
        :skip
    end
  rescue
    _ -> :skip
  end

  @doc false
  def mtime_to_age_seconds(mtime) when is_tuple(mtime) do
    :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) -
      :calendar.datetime_to_gregorian_seconds(mtime)
  end

  @doc false
  def mtime_to_age_seconds(_mtime), do: 0
end

defmodule Mix.Tasks.Batamanta do
  @moduledoc """
  Main Mix task to generate the monolithic binary.

  This task orchestrates the fetching of ERTS, packaging of the release/escript,
  and compilation of the Rust wrapper.

  ## Output Formats

  Batamanta supports two output formats:
  - `:release` (default) - Full OTP release with supervisor tree
  - `:escript` - Lightweight escript with embedded Elixir runtime

  For projects using `mix escript.build`, use:

      batamanta: [
        format: :escript
      ]

  ## OTP Version Control

  **User specifies, user owns.** If you specify `otp_version`, that exact version
  is used. If not specified (auto mode), a conservative fallback is used.

      batamanta: [
        otp_version: "28.1"  # Uses exact version, fails if not available
      ]

  In auto mode (no version specified), the system tries:
  - 28.0 → 28.1 → 28.2 → ... (fallback to first available)

  ## Automatic Cleanup and Cache

  Batamanta handles its own garbage. After each successful compilation, it:
  - **Removes** `bat_cargo_cache` from the system temp directory
  - **Deletes** `bat_pkg_*` and `bat_build_*` intermediate folders
  - **Preserves** the ERTS cache (`~/.cache/batamanta`) for sub-second repeat builds

  To manually wipe the entire cache (including downloaded ERTS), use `mix batamanta.clean`.

  ## ERTS Target Configuration

  Use `:erts_target` for unified platform specification:

      batamanta: [
        erts_target: :auto,              # Auto-detect or specific atom
        execution_mode: :cli,
        compression: 3,
        format: :escript                 # or :release
      ]

  ## Supported ERTS Targets

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

  ## Manual Overrides

  Force specific platform regardless of host:

      batamanta: [
        erts_target: :alpine_3_19_x86_64,  # Force Alpine musl
        force_os: "linux",                  # Or use individual overrides
        force_arch: "x86_64",
        force_libc: "musl",
        binary_name: "my_app"               # Force binary name
      ]

  ## Binary Name

  You can force the binary name by setting `:binary_name` in the config:

      batamanta: [
        binary_name: "my_custom_binary"
      ]

  ## Usage
      mix batamanta

  ## CLI Options
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

    # Clean up any stale temp directories from previous runs before starting
    cleanup_stale_temporaries()

    opts = parse_options(args)
    config = Mix.Project.config()
    bata_config = Keyword.get(config, :batamanta, [])

    # Resolve format: CLI option > config > auto-detect
    format = resolve_format(opts, bata_config, config)

    # Resolve ERTS configuration
    erts_target = resolve_erts_target(opts, bata_config)
    override_config = build_override_config(opts, bata_config)
    binary_name = override_config.binary_name

    # Resolve target and get info
    {:ok, resolved_target} = Target.resolve_auto(erts_target, override_config)
    target_info = Target.get_target_info(resolved_target)

    # Get OTP version
    {otp_version, version_mode} = resolve_otp_version(opts, bata_config)

    # Build banner (if enabled) - returns context for streaming logs
    show_banner = Keyword.get(bata_config, :show_banner, true)

    banner_ctx =
      build_banner(otp_version, target_info, resolved_target, show_banner, version_mode, format)

    # Validate configuration
    execution_mode = Keyword.get(bata_config, :execution_mode, :cli)
    Validator.validate!(os: target_info.os, arch: target_info.arch, mode: execution_mode)

    # 🔴 CRÍTICO: Validar libc para Linux
    if target_info.os == "linux" do
      Target.validate_libc!(resolved_target)
    end

    compression = opts[:compression] || bata_config[:compression] || 3

    # Fetch ERTS and execute appropriate pipeline
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

  @doc """
  Resolves the output format from options, config, or auto-detection.

  Priority:
  1. CLI option `--format`
  2. Config `format:` key
  3. Auto-detect: if project has `:escript` config, use `:escript`, else `:release`
  """
  def resolve_format(opts, bata_config, project_config) do
    # 1. Check CLI option
    if format = Keyword.get(opts, :format) do
      normalized = normalize_format(format)
      validate_format!(normalized)
      normalized
    else
      # 2. Check config
      if format = Keyword.get(bata_config, :format) do
        validate_format!(format)
        format
      else
        # 3. Auto-detect from project config
        auto_detected_format(project_config)
      end
    end
  end

  # Normalize format to atom (CLI passes strings)
  defp normalize_format(format) when is_binary(format), do: String.to_atom(format)
  defp normalize_format(format) when is_atom(format), do: format

  defp auto_detected_format(config) do
    # If project has :escript config, it's designed for escript
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

  ## User Control
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

  # Fetches ERTS based on version and mode.
  defp fetch_erts({otp_version, mode}, resolved_target, _target_info, banner_ctx) do
    # Note: The fetcher already handles all logging (URL, fetching, cached, etc.)
    # to avoid duplicate messages. The caller should not print additional messages.

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

  # Release pipeline (original behavior)
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

    # Get clean environment (without asdf/mise/kerl paths)
    clean_env = EnvCleaner.clean_env_tuples()
    env_with_mix = [{"MIX_ENV", "prod"} | clean_env]

    # Run release isolated in a subprocess to ensure compiler/mix stdout is totally silenced
    {out, status} =
      System.cmd("mix", ["release", "--overwrite", "--quiet"],
        env: env_with_mix,
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

  # Escript pipeline (new behavior)
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

    # Build the escript (pass erts_path to ensure build uses same ERTS as runtime)
    escript_path = EscriptBuilder.build(config, banner_ctx, erts_path)

    payload_path =
      Path.join(System.tmp_dir!(), "payload_#{:erlang.unique_integer([:positive])}.tar.zst")

    Logger.info(banner_ctx, ">> 📦 Packaging Escript (Zstd level #{compression})...")

    case EscriptPackager.package(escript_path, erts_path, payload_path, compression) do
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

  defp get_release_path(app) do
    # The release is built with MIX_ENV=prod, so we need to construct the prod path
    # Mix.Project.build_path() returns _build/<current_env>/<app>.beam
    # We need to go up and change to prod
    current_build = Mix.Project.build_path()

    # Extract project root by going up from _build/<env>/<app>.beam
    project_root =
      current_build
      # _build/<env>
      |> Path.dirname()
      # project root
      |> Path.dirname()

    # Construct prod release path
    Path.join([project_root, "_build", "prod", "rel", Atom.to_string(app)])
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

    # Show banner with context to allow streaming logs and image update
    Banner.show_with_context(messages,
      show_banner: show_banner,
      on_success_image: "batamantaman_happy.png",
      on_error_image: "batamantaman_sad.png"
    )
  end

  defp cleanup_temporaries(_ctx) do
    # 1. Clean Rust cargo cache target dir
    cargo_target_dir = Path.join(System.tmp_dir!(), "bat_cargo_cache")

    if File.exists?(cargo_target_dir) do
      File.rm_rf(cargo_target_dir)
    end

    # 2. Clean packaging / payload directories
    System.tmp_dir!()
    |> Path.join("bat_pkg_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    # 3. Clean rust build directories
    System.tmp_dir!()
    |> Path.join("bat_build_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)

    # 4. Clean batamanta extraction directories
    System.tmp_dir!()
    |> Path.join("batamanta_*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
  end

  # Cleans stale temp directories from previous runs on startup
  # This ensures a clean state and prevents accumulation of old builds
  defp cleanup_stale_temporaries do
    temp_base = System.tmp_dir!()

    # List of patterns to clean (old style - should cover most cases)
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
          # Only clean if it's older than 1 hour (in case current build is running)
          case File.stat(dir) do
            {:ok, %{mtime: mtime}} ->
              age_seconds = NaiveDateTime.diff(NaiveDateTime.utc_now(), mtime, :second)

              if age_seconds > 3600 do
                File.rm_rf(dir)
              end

            _ ->
              :skip
          end
        rescue
          _ -> :skip
        end
      end)
    end)

    # Also clean Mix build artifacts in _build that might be stale
    # but preserve the prod release if it exists (needed for packaging)
    clean_mix_build_artifacts()
  end

  # Clean stale Mix build artifacts while preserving current release/escript
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
        age_seconds = NaiveDateTime.diff(NaiveDateTime.utc_now(), mtime, :second)

        # Only clean if older than 24 hours
        if age_seconds > 86_400 do
          File.rm_rf(dir)
        end

      _ ->
        :skip
    end
  rescue
    _ -> :skip
  end
end

defmodule Mix.Tasks.Batamanta do
  @moduledoc """
  Main Mix task to generate the monolithic binary.

  This task orchestrates the fetching of ERTS, packaging of the release,
  and compilation of the Rust wrapper.

  ## OTP Version Control

  **User specifies, user owns.** If you specify `otp_version`, that exact version
  is used. If not specified (auto mode), a conservative fallback is used.

      batamanta: [
        otp_version: "28.1"  # Uses exact version, fails if not available
      ]

  In auto mode (no version specified), the system tries:
  - 28.0 → 28.1 → 28.2 → ... (fallback to first available)

  ## ERTS Target Configuration

  Use `:erts_target` for unified platform specification:

      batamanta: [
        erts_target: :auto,              # Auto-detect or specific atom
        execution_mode: :cli,
        compression: 3
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
  | `:windows_x86_64` | Windows (coming soon) |

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
  """
  use Mix.Task

  alias Batamanta.Banner
  alias Batamanta.ERTS
  alias Batamanta.Logger
  alias Batamanta.Packager
  alias Batamanta.RustTemplate
  alias Batamanta.Target
  alias Batamanta.Validator

  @shortdoc "Generates a monolithic binary"

  @impl Mix.Task
  def run(args) do
    validate_toolchain!()

    opts = parse_options(args)
    config = Mix.Project.config()
    bata_config = Keyword.get(config, :batamanta, [])

    # Resolver configuración
    erts_target = resolve_erts_target(opts, bata_config)
    override_config = build_override_config(opts, bata_config)
    binary_name = override_config.binary_name

    # Resolver target y obtener información
    {:ok, resolved_target} = Target.resolve_auto(erts_target, override_config)
    target_info = Target.get_target_info(resolved_target)

    # Obtener versión de OTP
    {otp_version, version_mode} = resolve_otp_version(opts, bata_config)

    # Build banner (if enabled) - returns context for streaming logs
    show_banner = Keyword.get(bata_config, :show_banner, true)

    banner_ctx =
      build_banner(otp_version, target_info, resolved_target, show_banner, version_mode)

    # Validar configuración
    execution_mode = Keyword.get(bata_config, :execution_mode, :cli)
    Validator.validate!(os: target_info.os, arch: target_info.arch, mode: execution_mode)

    # 🔴 CRÍTICO: Validar libc para Linux
    if target_info.os == "linux" do
      Target.validate_libc!(resolved_target)
    end

    compression = opts[:compression] || bata_config[:compression] || 3

    # Fetch ERTS y ejecutar pipeline
    with {:ok, erts_path} <- fetch_erts(otp_version, resolved_target, target_info, banner_ctx) do
      execute_pipeline(
        config,
        resolved_target,
        target_info,
        erts_path,
        compression,
        binary_name,
        banner_ctx
      )
    end
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
          otp_version: :string
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
         banner_ctx
       ) do
    Logger.info(banner_ctx, ">> 📦 Creating Release...")

    # Run release isolated in a subprocess to ensure compiler/mix stdout is totally silenced
    {_out, status} =
      System.cmd("mix", ["release", "--overwrite", "--quiet"],
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      Banner.set_image(banner_ctx, :error)
      Mix.raise("Mix release compilation failed.")
    end

    payload_path =
      Path.join(System.tmp_dir!(), "payload_#{:erlang.unique_integer([:positive])}.tar.zst")

    release_path = get_release_path(config[:app])

    Logger.info(banner_ctx, ">> 📦 Packaging Payload (Zstd level #{compression})...")

    case Packager.package(release_path, erts_path, payload_path, compression) do
      {:ok, _} ->
        compile_wrapper(config, payload_path, erts_target, target_info, binary_name, banner_ctx)
        File.rm(payload_path)

      {:error, reason} ->
        Banner.set_image(banner_ctx, :error)
        Mix.raise("Packaging Error: #{reason}")
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

  defp compile_wrapper(config, payload_path, erts_target, target_info, binary_name, banner_ctx) do
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

    case RustTemplate.build(payload_path, final_name, rust_target, config) do
      :ok ->
        apply_minify(final_name, banner_ctx)
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

  defp build_banner(otp_version, target_info, _resolved_target, show_banner, version_mode) do
    mode_str = if version_mode == :explicit, do: " (user-specified)", else: " (auto-detected)"

    messages = [
      ">> 🖥️  OS: #{target_info.os}",
      ">> ⚙️  Architecture: #{target_info.arch}",
      ">> 📦 Type: #{target_info.libc || "N/A"}",
      ">> 🔢 ERTS: #{otp_version}#{mode_str}"
    ]

    # Show banner with context to allow streaming logs and image update
    Banner.show_with_context(messages,
      show_banner: show_banner,
      on_success_image: "batamantaman_happy.png",
      on_error_image: "batamantaman_sad.png"
    )
  end
end

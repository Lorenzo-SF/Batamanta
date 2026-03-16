defmodule Mix.Tasks.Batamanta do
  @moduledoc """
  Main Mix task to generate the monolithic binary.

  This task orchestrates the fetching of ERTS, packaging of the release,
  and compilation of the Rust wrapper.

  ## New Unified Configuration

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
    otp_version = resolve_otp_version(opts, bata_config)

    # Build banner (if enabled) - returns context for streaming logs
    show_banner = Keyword.get(bata_config, :show_banner, true)
    banner_ctx = build_banner(otp_version, target_info, resolved_target, show_banner)

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
          compression: :integer
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
  """
  def resolve_otp_version(opts, bata_config) do
    Keyword.get(bata_config, :otp_version) ||
      Keyword.get(opts, :otp_version) ||
      :erlang.system_info(:otp_release) |> to_string()
  end

  defp fetch_erts(otp_version, resolved_target, _target_info, banner_ctx) do
    url = ERTS.Fetcher.build_download_url(otp_version, resolved_target)
    Logger.info(banner_ctx, ">> 🔗 URL: #{url}")

    case ERTS.Fetcher.fetch(otp_version, resolved_target) do
      {:ok, erts_path} ->
        Logger.info(banner_ctx, ">> ✅ ERTS cached at: #{erts_path}")
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
    Mix.Project.build_path()
    |> Path.join("rel")
    |> Path.join(Atom.to_string(app))
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

  defp build_banner(otp_version, target_info, _resolved_target, show_banner) do
    messages = [
      ">> 🖥️  OS: #{target_info.os}",
      ">> ⚙️  Architecture: #{target_info.arch}",
      ">> 📦 Type: #{target_info.libc || "N/A"}",
      ">> 🔢 ERTS: #{otp_version}"
    ]

    # Show banner with context to allow streaming logs and image update
    Banner.show_with_context(messages,
      show_banner: show_banner,
      on_success_image: "batamantaman_happy.png",
      on_error_image: "batamantaman_sad.png"
    )
  end
end

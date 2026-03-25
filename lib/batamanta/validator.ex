defmodule Batamanta.Validator do
  @moduledoc """
  Validates Batamanta configuration for supported combinations.

  This module ensures that the combination of OS, architecture, OTP version,
  Elixir version, and execution mode is valid and supported.

  ## Compatibility Matrix

  ### Supported OS
  - `:macos` - macOS 11+ (Big Sur and later)
  - `:linux` - Linux with glibc (Debian, Ubuntu, Arch, Fedora, etc.)
  - `:linux_musl` - Linux with musl (Alpine)
  - `:windows` - Windows 10+ (limited support)

  ### Supported Architectures
  - `:x86_64` - Intel/AMD 64-bit
  - `:aarch64` - ARM 64-bit (Apple Silicon, ARM servers)

  ### Supported OTP Versions
  - OTP 25+ (minimum supported)
  - OTP 26, 27, 28+ (recommended)

  ### Supported Elixir Versions
  - Elixir 1.15+ (minimum supported)
  - Elixir 1.16, 1.17, 1.18+ (recommended)

  ### Supported Execution Modes
  - `:cli` - Command-line interface (all platforms)
  - `:tui` - Text user interface (Unix only)
  - `:daemon` - Background daemon (Unix only)

  ## Examples

      iex> Batamanta.Validator.validate!(os: "linux", arch: "x86_64", mode: :cli)
      :ok

      iex> Batamanta.Validator.validate!(os: "windows", mode: :tui)
      ** (ArgumentError) TUI mode is not supported on Windows

  """

  @type validation_config :: [
          os: String.t() | :auto,
          arch: String.t() | :auto,
          mode: atom(),
          otp_version: String.t(),
          elixir_version: String.t()
        ]

  @supported_os ["linux", "macos", "windows"]
  @supported_arch ["x86_64", "aarch64"]
  @supported_modes [:cli, :tui, :daemon]
  @min_otp_version 25
  @min_elixir_version "1.15.0"

  @doc """
  Validates the configuration and returns `:ok` or raises an error.

  ## Parameters
    - `config` - Keyword list with validation parameters

  ## Examples

      iex> validate!(os: "linux", arch: "x86_64", mode: :cli)
      :ok

  """
  @spec validate!(validation_config()) :: :ok | no_return()
  def validate!(config) do
    config
    |> validate_os()
    |> validate_arch()
    |> validate_mode()
    |> validate_otp_version()
    |> validate_elixir_version()
    |> validate_os_mode_combination()

    :ok
  end

  @doc """
  Returns a list of all supported combinations.
  """
  @spec supported_combinations() :: list(map())
  def supported_combinations do
    for os <- @supported_os,
        arch <- @supported_arch,
        mode <- @supported_modes,
        valid_combination?(%{os: os, arch: arch, mode: mode}),
        do: %{os: os, arch: arch, mode: mode}
  end

  @doc """
  Checks if a specific combination is valid.
  """
  @spec valid_combination?(map()) :: boolean()
  def valid_combination?(%{os: os, mode: mode}) do
    # TUI and daemon are not supported on Windows
    if os == "windows" and mode in [:tui, :daemon] do
      false
    else
      true
    end
  end

  def valid_combination?(_), do: false

  # Private validation functions

  defp validate_os(config) do
    case Keyword.get(config, :os) do
      nil ->
        config

      :auto ->
        config

      os when os in @supported_os ->
        config

      os ->
        raise ArgumentError,
              "Unsupported OS: #{inspect(os)}. Supported: #{inspect(@supported_os)}"
    end
  end

  defp validate_arch(config) do
    case Keyword.get(config, :arch) do
      nil ->
        config

      :auto ->
        config

      arch when arch in @supported_arch ->
        config

      arch ->
        raise ArgumentError,
              "Unsupported architecture: #{inspect(arch)}. Supported: #{inspect(@supported_arch)}"
    end
  end

  defp validate_mode(config) do
    case Keyword.get(config, :mode) do
      nil ->
        config

      mode when mode in @supported_modes ->
        config

      mode ->
        raise ArgumentError,
              "Unsupported execution mode: #{inspect(mode)}. Supported: #{inspect(@supported_modes)}"
    end
  end

  defp validate_otp_version(config) do
    case Keyword.get(config, :otp_version) do
      nil ->
        config

      version ->
        otp_num =
          case Integer.parse(version) do
            {num, _} -> num
            :error -> raise ArgumentError, "Invalid OTP version: #{inspect(version)}"
          end

        if otp_num < @min_otp_version do
          raise ArgumentError,
                "OTP version must be >= #{@min_otp_version}, got: #{otp_num}"
        end

        config
    end
  end

  defp validate_elixir_version(config) do
    case Keyword.get(config, :elixir_version) do
      nil ->
        config

      version ->
        # Normalize version to semver format (X.Y.Z)
        normalized_version = normalize_version(version)

        if Version.compare(normalized_version, @min_elixir_version) == :lt do
          raise ArgumentError,
                "Elixir version must be >= #{@min_elixir_version}, got: #{version}"
        end

        config
    end
  end

  # Normalize version strings to semver format
  defp normalize_version(version) when is_binary(version) do
    parts = String.split(version, ".")

    case length(parts) do
      1 -> "#{version}.0.0"
      2 -> "#{version}.0"
      _ -> version
    end
  end

  defp validate_os_mode_combination(config) do
    os = Keyword.get(config, :os)
    mode = Keyword.get(config, :mode)

    cond do
      is_nil(os) or is_nil(mode) ->
        config

      os == "windows" and mode in [:tui, :daemon] ->
        raise ArgumentError,
              "Mode #{inspect(mode)} is not supported on Windows. " <>
                "Only :cli mode is supported on Windows."

      true ->
        config
    end
  end

  @doc """
  Returns a human-readable compatibility matrix.
  """
  @spec compatibility_matrix() :: String.t()
  def compatibility_matrix do
    """
    ╔══════════════════════════════════════════════════════════════════╗
    ║              BATAMANTA COMPATIBILITY MATRIX                       ║
    ╚══════════════════════════════════════════════════════════════════╝

    OPERATING SYSTEMS
    ────────────────────────────────────────────────────────────────────
    ✅ macOS (11+)           - x86_64, aarch64 (Apple Silicon)
    ✅ Linux (glibc)         - x86_64, aarch64 (Debian, Ubuntu, Arch...)
    ✅ Linux (musl)          - x86_64, aarch64 (Alpine)
    🔲 Windows (10+)         - x86_64 (CLI mode only, coming soon)

    EXECUTION MODES
    ────────────────────────────────────────────────────────────────────
    ✅ :cli                  - Command-line interface (all platforms)
    ✅ :tui                  - Text user interface (Unix only)
    ✅ :daemon               - Background daemon (Unix only)

    OTP VERSIONS
    ────────────────────────────────────────────────────────────────────
    ✅ OTP 25                - Minimum supported version
    ✅ OTP 26                - Recommended
    ✅ OTP 27                - Recommended
    ✅ OTP 28+               - Latest

    ELIXIR VERSIONS
    ────────────────────────────────────────────────────────────────────
    ✅ Elixir 1.15           - Minimum supported version
    ✅ Elixir 1.16           - Recommended
    ✅ Elixir 1.17           - Recommended
    ✅ Elixir 1.18+          - Latest

    RESTRICTIONS
    ────────────────────────────────────────────────────────────────────
    ❌ Windows + :tui        - TUI requires Unix terminal capabilities
    ❌ Windows + :daemon     - Daemons require Unix process management
    ❌ OTP < 25             - Missing required BEAM features
    ❌ Elixir < 1.15        - Missing required language features

    RECOMMENDED CONFIGURATIONS
    ────────────────────────────────────────────────────────────────────
    🏆 macOS + OTP 28 + Elixir 1.18 + :cli/:tui/:daemon
    🏆 Linux (glibc) + OTP 28 + Elixir 1.18 + :cli/:tui/:daemon
    🏆 Linux (musl) + OTP 27 + Elixir 1.17 + :cli/:daemon
    """
  end
end

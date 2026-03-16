defmodule Batamanta.Target do
  @moduledoc """
  Handles target platform resolution and Rust target mapping.

  Provides functions to resolve ERTS targets into Rust target triples
  and platform-specific configuration.

  ## New Unified Configuration

  Use `:erts_target` atoms for unified platform specification:

      iex> Batamanta.Target.erts_target_to_rust(:ubuntu_22_04_x86_64)
      "x86_64-unknown-linux-gnu"

  ## Supported ERTS Targets

  | Target Atom | OS | Arch | Libc | Rust Target |
  |-------------|-----|------|------|-------------|
  | `:ubuntu_22_04_x86_64` | Linux | x86_64 | glibc | x86_64-unknown-linux-gnu |
  | `:ubuntu_22_04_arm64` | Linux | aarch64 | glibc | aarch64-unknown-linux-gnu |
  | `:alpine_3_19_x86_64` | Linux | x86_64 | musl | x86_64-unknown-linux-musl |
  | `:alpine_3_19_arm64` | Linux | aarch64 | musl | aarch64-unknown-linux-musl |
  | `:macos_12_x86_64` | macOS | x86_64 | - | x86_64-apple-darwin |
  | `:macos_12_arm64` | macOS | aarch64 | - | aarch64-apple-darwin |
  | `:windows_x86_64` | Windows | x86_64 | msvc | x86_64-pc-windows-msvc |

  """

  @type erts_target :: atom()
  @type rust_target :: String.t()
  @type target_info :: %{
          os: String.t(),
          arch: String.t(),
          libc: String.t() | nil,
          rust_target: rust_target(),
          display: String.t()
        }

  # ============================================================================
  # MATRIZ UNIFICADA DE TARGETS
  # ============================================================================

  @target_matrix %{
    # Linux glibc (Ubuntu 22.04 para máxima compatibilidad)
    ubuntu_22_04_x86_64: %{
      os: "linux",
      arch: "x86_64",
      libc: "gnu",
      rust_target: "x86_64-unknown-linux-gnu",
      erts_os: "linux",
      erts_arch: "x86_64",
      display: "Linux x86_64 (glibc)"
    },
    ubuntu_22_04_arm64: %{
      os: "linux",
      arch: "aarch64",
      libc: "gnu",
      rust_target: "aarch64-unknown-linux-gnu",
      erts_os: "linux",
      erts_arch: "aarch64",
      display: "Linux aarch64 (glibc)"
    },

    # Linux musl (Alpine)
    alpine_3_19_x86_64: %{
      os: "linux",
      arch: "x86_64",
      libc: "musl",
      rust_target: "x86_64-unknown-linux-musl",
      erts_os: "linux",
      erts_arch: "x86_64",
      display: "Linux x86_64 (musl)"
    },
    alpine_3_19_arm64: %{
      os: "linux",
      arch: "aarch64",
      libc: "musl",
      rust_target: "aarch64-unknown-linux-musl",
      erts_os: "linux",
      erts_arch: "aarch64",
      display: "Linux aarch64 (musl)"
    },

    # macOS
    macos_12_x86_64: %{
      os: "macos",
      arch: "x86_64",
      libc: nil,
      rust_target: "x86_64-apple-darwin",
      erts_os: "macos",
      erts_arch: "x86_64",
      display: "macOS x86_64"
    },
    macos_12_arm64: %{
      os: "macos",
      arch: "aarch64",
      libc: nil,
      rust_target: "aarch64-apple-darwin",
      erts_os: "macos",
      erts_arch: "aarch64",
      display: "macOS aarch64 (Apple Silicon)"
    },

    # Windows
    windows_x86_64: %{
      os: "windows",
      arch: "x86_64",
      libc: "msvc",
      rust_target: "x86_64-pc-windows-msvc",
      erts_os: "windows-2019",
      erts_arch: "x86_64",
      display: "Windows x86_64"
    }
  }

  @doc """
  Resolves an ERTS target atom to comprehensive target information.

  ## Parameters
    - `erts_target` - Target atom (e.g., `:ubuntu_22_04_x86_64`)

  ## Returns
    `{:ok, target_info_map}` or `{:error, reason}`

  ## Examples

      iex> Batamanta.Target.resolve(:ubuntu_22_04_x86_64)
      {:ok, %{os: "linux", arch: "x86_64", libc: "gnu", ...}}

  """
  @spec resolve(erts_target()) :: {:ok, target_info()} | {:error, String.t()}
  def resolve(erts_target) when is_atom(erts_target) do
    case Map.get(@target_matrix, erts_target) do
      nil ->
        {:error,
         "Unknown ERTS target: #{inspect(erts_target)}. Valid: #{inspect(valid_targets())}"}

      info ->
        {:ok, info}
    end
  end

  @doc """
  Converts an ERTS target atom to a Rust target triple.

  ## Examples

      iex> Batamanta.Target.erts_target_to_rust(:ubuntu_22_04_x86_64)
      "x86_64-unknown-linux-gnu"

      iex> Batamanta.Target.erts_target_to_rust(:alpine_3_19_x86_64)
      "x86_64-unknown-linux-musl"

  """
  @spec erts_target_to_rust(erts_target()) :: rust_target()
  def erts_target_to_rust(erts_target) do
    case resolve(erts_target) do
      {:ok, info} -> info.rust_target
      {:error, _} -> raise "Invalid ERTS target: #{inspect(erts_target)}"
    end
  end

  @doc """
  Converts an ERTS target atom to a user-friendly binary name.

  ## Examples

      iex> Batamanta.Target.erts_target_to_display(:ubuntu_22_04_x86_64)
      "Linux x86_64 (glibc)"

  """
  @spec erts_target_to_display(erts_target()) :: String.t()
  def erts_target_to_display(erts_target) do
    case resolve(erts_target) do
      {:ok, info} -> info.display
      {:error, _} -> inspect(erts_target)
    end
  end

  @doc """
  Gets the target info map for a given target atom.

  ## Examples

      iex> Batamanta.Target.get_target_info(:ubuntu_22_04_x86_64)
      %{os: "linux", arch: "x86_64", libc: "gnu", ...}

  """
  @spec get_target_info(erts_target()) :: map() | nil
  def get_target_info(target), do: Map.get(@target_matrix, target)

  @doc """
  Gets the OS string for binary naming (e.g., "x86_64-linux").
  """
  @spec erts_target_to_binary_suffix(erts_target()) :: String.t()
  def erts_target_to_binary_suffix(erts_target) do
    case resolve(erts_target) do
      {:ok, info} ->
        "#{info.arch}-#{info.os}"

      {:error, _} ->
        raise "Invalid ERTS target: #{inspect(erts_target)}"
    end
  end

  @doc """
  Lists all valid ERTS target atoms.
  """
  @spec valid_targets() :: list(atom())
  def valid_targets, do: Map.keys(@target_matrix)

  @doc """
  Detects the host platform and returns the matching ERTS target.

  Delegates to `Batamanta.ERTS.Fetcher.detect_host_target/0`.

  ## Examples

      iex> Batamanta.Target.detect_host()
      {:ok, :ubuntu_22_04_x86_64}

  """
  @spec detect_host() :: {:ok, erts_target()} | {:error, String.t()}
  def detect_host do
    Batamanta.ERTS.Fetcher.detect_host_target()
  end

  @doc """
  Detects the libc type of the current Linux system.

  Delegates to `Batamanta.ERTS.LibcDetector.detect/0`.

  ## Examples

      iex> Batamanta.Target.detect_libc()
      :gnu

      iex> Batamanta.Target.detect_libc()
      :musl

  """
  @spec detect_libc() :: :gnu | :musl | :unknown
  def detect_libc do
    case :os.type() do
      {:unix, :linux} ->
        Batamanta.ERTS.LibcDetector.detect()

      _ ->
        :unknown
    end
  end

  @doc """
  Validates that the detected libc matches an expected target.

  Shows a warning if there's a mismatch but doesn't fail.

  ## Examples

      iex> Batamanta.Target.validate_libc!(:ubuntu_22_04_x86_64)
      :ok

  """
  @spec validate_libc!(erts_target()) :: :ok
  def validate_libc!(target) do
    detected_libc = detect_libc()
    expected_libc = get_libc_from_target(target)

    do_validate_libc(detected_libc, expected_libc, target)
  end

  defp do_validate_libc(detected_libc, expected_libc, _target)
       when detected_libc == expected_libc or detected_libc == :unknown do
    :ok
  end

  defp do_validate_libc(detected_libc, expected_libc, _target) do
    Mix.shell().info(
      IO.ANSI.red() <>
        "⚠️  libc mismatch detected!" <> IO.ANSI.reset()
    )

    Mix.shell().info(
      "  Expected: #{get_libc_display(expected_libc)}\n" <>
        "  Detected: #{get_libc_display(detected_libc)}\n" <>
        "  This may cause runtime issues. Consider using:\n" <>
        "    mix batamanta --erts-target #{get_target_for_libc(detected_libc)}\n"
    )

    :ok
  end

  defp get_libc_from_target(target) do
    case Map.get(@target_matrix, target) do
      %{libc: "musl"} -> :musl
      %{libc: "gnu"} -> :gnu
      %{libc: "msvc"} -> :msvc
      _ -> :gnu
    end
  end

  defp get_libc_display(libc) do
    case libc do
      :musl -> "musl libc (Alpine)"
      :gnu -> "glibc (Debian/Ubuntu/Arch/Fedora)"
      :msvc -> "MSVCRT (Windows)"
      _ -> "Unknown"
    end
  end

  defp get_target_for_libc(libc) do
    case libc do
      :musl -> "alpine_3_19_x86_64"
      :gnu -> "ubuntu_22_04_x86_64"
      _ -> "ubuntu_22_04_x86_64"
    end
  end

  @doc """
  Resolves `:auto` or string/atom target to a concrete ERTS target atom.

  ## Parameters
    - `target` - `:auto`, atom, or string
    - `config` - Optional config map with `:force_os`, `:force_arch`, `:force_libc`

  ## Returns
    `{:ok, erts_target_atom}` or `{:error, reason}`

  ## Examples

      iex> Batamanta.Target.resolve_auto(:auto, %{})
      {:ok, :ubuntu_22_04_x86_64}

      iex> Batamanta.Target.resolve_auto(:alpine_3_19_x86_64, %{})
      {:ok, :alpine_3_19_x86_64}

  """
  @spec resolve_auto(atom() | String.t() | nil, map()) ::
          {:ok, erts_target()} | {:error, String.t()}
  def resolve_auto(target, config \\ %{})

  def resolve_auto(:auto, config) do
    resolve_auto_mode(config)
  end

  def resolve_auto(target_atom, _config) when is_atom(target_atom) do
    resolve_atom_target(target_atom)
  end

  def resolve_auto(target_str, _config) when is_binary(target_str) do
    resolve_string_target(target_str)
  end

  def resolve_auto(nil, config), do: resolve_auto(:auto, config)

  defp resolve_auto_mode(config) do
    if Map.get(config, :force_os) do
      build_target_from_overrides(config)
    else
      detect_host()
    end
  end

  defp resolve_atom_target(target_atom) do
    if target_atom in valid_targets() do
      {:ok, target_atom}
    else
      {:error, "Invalid ERTS target: #{inspect(target_atom)}"}
    end
  end

  defp resolve_string_target(target_str) do
    target_atom = String.to_atom(target_str)

    if target_atom in valid_targets() do
      {:ok, target_atom}
    else
      {:error, "Invalid ERTS target: #{target_str}"}
    end
  end

  # ============================================================================
  # FUNCIONES AUXILIARES
  # ============================================================================

  @spec build_target_from_overrides(map()) :: {:ok, erts_target()} | {:error, String.t()}
  defp build_target_from_overrides(config) do
    os = Map.get(config, :force_os)
    arch = Map.get(config, :force_arch)
    libc = Map.get(config, :force_libc)

    do_build_target(os, arch, libc)
  end

  defp do_build_target("linux", "x86_64", "musl"), do: {:ok, :alpine_3_19_x86_64}
  defp do_build_target("linux", "aarch64", "musl"), do: {:ok, :alpine_3_19_arm64}

  defp do_build_target("linux", "x86_64", gnu) when gnu == "gnu" or is_nil(gnu),
    do: {:ok, :ubuntu_22_04_x86_64}

  defp do_build_target("linux", "aarch64", gnu) when gnu == "gnu" or is_nil(gnu),
    do: {:ok, :ubuntu_22_04_arm64}

  defp do_build_target("macos", "x86_64", _), do: {:ok, :macos_12_x86_64}
  defp do_build_target("macos", "aarch64", _), do: {:ok, :macos_12_arm64}
  defp do_build_target("windows", "x86_64", _), do: {:ok, :windows_x86_64}
  defp do_build_target(_, _, _), do: {:error, "Could not resolve target from overrides"}

  @doc """
  Legacy compatibility: converts old target_os/target_arch to new erts_target.

  ## Examples

      iex> Batamanta.Target.from_legacy("linux", "x86_64")
      :ubuntu_22_04_x86_64

  """
  @spec from_legacy(String.t() | :auto, String.t() | :auto) :: erts_target()
  def from_legacy(os, arch) do
    case {os, arch} do
      {:auto, :auto} ->
        detect_host_or_default()

      {"linux", "x86_64"} ->
        :ubuntu_22_04_x86_64

      {"linux", "aarch64"} ->
        :ubuntu_22_04_arm64

      {"macos", "x86_64"} ->
        :macos_12_x86_64

      {"macos", "aarch64"} ->
        :macos_12_arm64

      {"windows", "x86_64"} ->
        :windows_x86_64

      _ ->
        :ubuntu_22_04_x86_64
    end
  end

  defp detect_host_or_default do
    case detect_host() do
      {:ok, target} -> target
    end
  end
end

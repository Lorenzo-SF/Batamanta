defmodule Batamanta.ERTS.LibcDetector do
  @moduledoc """
  Robust libc detection for Linux platforms.

  Uses multiple methods in order of reliability to detect whether the system
  uses glibc or musl libc. This is critical for selecting the correct ERTS
  build for cross-platform compatibility.

  ## Detection Methods

  The detector uses these methods in order:

  1. **ldd --version** - Most reliable for runtime detection
  2. **Dynamic loader check** - Most reliable for cross-compile
  3. **/etc/os-release** - Fallback for known distributions
  4. **/proc/self/maps** - Advanced fallback

  ## Examples

      iex> Batamanta.ERTS.LibcDetector.detect()
      :gnu

      iex> Batamanta.ERTS.LibcDetector.detect()
      :musl

  """

  @type libc_type :: :gnu | :musl | :unknown

  @doc """
  Detects the libc type of the current system.

  Returns `:gnu` for glibc-based systems (Debian, Ubuntu, Arch, Fedora, etc.)
  or `:musl` for musl-based systems (Alpine, Void Linux, etc.).

  Always returns either `:gnu` or `:musl` - never `:unknown` (uses fallback).

  ## Examples

      iex> Batamanta.ERTS.LibcDetector.detect()
      :gnu

  """
  @spec detect() :: :gnu | :musl
  def detect do
    # Método 1: ldd --version (MÁS CONFIABLE)
    case detect_by_ldd() do
      :unknown -> detect_by_loader()
      result -> result
    end
  end

  @doc """
  Detects libc by running `ldd --version`.

  This is the most reliable method for runtime detection on the current system.
  """
  @spec detect_by_ldd() :: libc_type()
  def detect_by_ldd do
    # Verificar si ldd existe antes de ejecutarlo
    if System.find_executable("ldd") == nil do
      :unknown
    else
      do_detect_by_ldd()
    end
  end

  defp do_detect_by_ldd do
    case System.cmd("ldd", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        cond do
          # musl se identifica claramente
          String.match?(output, ~r/musl/i) ->
            :musl

          # glibc tiene múltiples formatos
          String.match?(output, ~r/glibc/i) ->
            :gnu

          String.match?(output, ~r/GNU.*libc/i) ->
            :gnu

          String.match?(output, ~r/GNU C Library/i) ->
            :gnu

          true ->
            :unknown
        end

      # ldd disponible pero falló
      _ ->
        :unknown
    end
  end

  @doc """
  Detects libc by checking for dynamic loader files.

  This method works even when `ldd` is not available, making it suitable
  for cross-compilation scenarios.
  """
  @spec detect_by_loader() :: libc_type()
  def detect_by_loader do
    # Loaders específicos de musl (más confiables)
    musl_loaders = [
      "/lib/ld-musl-x86_64.so.1",
      "/lib/ld-musl-aarch64.so.1",
      "/lib/ld-musl-x32.so.1",
      "/lib/ld-musl-arm.so.1",
      "/lib/ld-musl-i386.so.1"
    ]

    # Loaders de glibc
    gnu_loaders = [
      "/lib64/ld-linux-x86-64.so.2",
      "/lib/ld-linux-aarch64.so.1",
      "/lib/ld-linux-armhf.so.3",
      "/lib/ld-linux.so.2"
    ]

    cond do
      # Verificar musl primero (más específico)
      Enum.any?(musl_loaders, &File.exists?/1) ->
        :musl

      # Verificar glibc
      Enum.any?(gnu_loaders, &File.exists?/1) ->
        :gnu

      true ->
        detect_by_os_release()
    end
  end

  @doc """
  Detects libc by reading `/etc/os-release`.

  This method works for known distributions but may fail for custom builds.
  """
  @spec detect_by_os_release() :: libc_type()
  def detect_by_os_release do
    case File.read("/etc/os-release") do
      {:ok, content} ->
        detect_by_os_release_content(content)

      _ ->
        # Fallback final: asumir glibc (más común)
        :gnu
    end
  end

  @spec detect_by_os_release_content(String.t()) :: libc_type()
  defp detect_by_os_release_content(content) do
    # Distros musl conocidos
    if musl_distro?(content) do
      :musl
    else
      :gnu
    end
  end

  defp musl_distro?(content) do
    # Verificar ID primero (más específico)
    alpine?(content) or
      void?(content) or
      postmarketos?(content) or
      alpine_like?(content) or
      has_musl_hint?(content)
  end

  defp alpine?(content), do: String.match?(content, ~r/^ID="?alpine"?/im)
  defp void?(content), do: String.match?(content, ~r/^ID="?void"?/im)
  defp postmarketos?(content), do: String.match?(content, ~r/^ID="?postmarketos"?/im)
  defp alpine_like?(content), do: String.match?(content, ~r/^ID_LIKE="?alpine"?/im)
  defp has_musl_hint?(content), do: String.match?(content, ~r/musl/i)

  @doc """
  Detects libc by reading `/proc/self/maps`.

  Advanced method that checks which libc is loaded in memory.
  """
  @spec detect_by_proc_maps() :: libc_type()
  def detect_by_proc_maps do
    case File.read("/proc/self/maps") do
      {:ok, content} ->
        detect_by_proc_maps_content(content)

      _ ->
        :unknown
    end
  end

  defp detect_by_proc_maps_content(content) do
    cond do
      # Buscar referencias explícitas a musl
      String.match?(content, ~r/libc\.musl/) ->
        :musl

      String.match?(content, ~r/ld-musl/) ->
        :musl

      # Referencias a glibc
      String.match?(content, ~r/libc-2\./) ->
        :gnu

      String.match?(content, ~r/libc-6\./) ->
        :gnu

      # libc.so genérico - verificar path
      String.match?(content, ~r/libc\.so/) ->
        if String.match?(content, ~r/libc-musl/), do: :musl, else: :gnu

      true ->
        :unknown
    end
  end

  @doc """
  Returns a human-readable description of the detected libc.
  """
  @spec describe(libc_type()) :: String.t()
  def describe(libc_type) do
    case libc_type do
      :gnu ->
        "GNU glibc (Debian, Ubuntu, Arch, Fedora, etc.)"

      :musl ->
        "musl libc (Alpine, Void Linux, etc.)"

      :unknown ->
        "Unknown (assuming glibc as fallback)"
    end
  end

  @doc """
  Validates that the detected libc matches an expected target.

  Returns `:ok` if they match, or an error tuple with details.
  """
  @spec validate!(libc_type(), atom()) :: :ok | no_return()
  def validate!(detected_libc, expected_target) do
    expected_libc = target_to_libc(expected_target)

    cond do
      detected_libc == expected_libc ->
        :ok

      detected_libc == :unknown ->
        Mix.shell().info(
          IO.ANSI.yellow() <>
            "⚠️  Could not detect libc type. Proceeding with assumed target." <> IO.ANSI.reset()
        )

        :ok

      true ->
        Mix.shell().info(
          IO.ANSI.red() <>
            "⚠️  libc mismatch detected!" <> IO.ANSI.reset()
        )

        Mix.shell().info(
          "  Expected: #{describe(expected_libc)}\n" <>
            "  Detected: #{describe(detected_libc)}\n" <>
            "  This may cause runtime issues. Consider using:\n" <>
            "    mix batamanta --erts-target #{libc_to_target(detected_libc)}\n"
        )

        :ok
    end
  end

  @spec target_to_libc(atom()) :: libc_type()
  defp target_to_libc(target) do
    case target do
      :alpine_3_19_x86_64 -> :musl
      :alpine_3_19_arm64 -> :musl
      :ubuntu_22_04_x86_64 -> :gnu
      :ubuntu_22_04_arm64 -> :gnu
      _ -> :gnu
    end
  end

  @spec libc_to_target(libc_type()) :: atom()
  defp libc_to_target(libc_type) do
    case libc_type do
      :musl -> :alpine_3_19_x86_64
      :gnu -> :ubuntu_22_04_x86_64
      :unknown -> :ubuntu_22_04_x86_64
    end
  end
end

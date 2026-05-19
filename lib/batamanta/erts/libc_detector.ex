defmodule Batamanta.ERTS.LibcDetector do
  @moduledoc """
  Robust libc detection for Linux platforms.

  Uses multiple methods in order of reliability to detect whether the system
  uses glibc or musl libc. This is critical for selecting the correct ERTS
  build for cross-platform compatibility.


  The detector uses these methods in order:

  1. **ldd --version** - Most reliable for runtime detection
  2. **Dynamic loader check** - Most reliable for cross-compile
  3. **/etc/os-release** - Fallback for known distributions
  4. **/proc/self/maps** - Advanced fallback


      iex> Batamanta.ERTS.LibcDetector.detect()
      :gnu

      iex> Batamanta.ERTS.LibcDetector.detect()
      :musl

  """

  @type libc_type :: :gnu | :musl | :unknown

  @musl_distros ~w(alpine void postmarketos)

  @doc """
  Detects the libc type of the current system.

  Returns `:gnu` for glibc-based systems (Debian, Ubuntu, Arch, Fedora, etc.)
  or `:musl` for musl-based systems (Alpine, Void Linux, etc.).

  Always returns either `:gnu` or `:musl` - never `:unknown` (uses fallback).


      iex> Batamanta.ERTS.LibcDetector.detect()
      :gnu

  """
  @spec detect() :: :gnu | :musl
  def detect do
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
    if System.find_executable("ldd") == nil do
      :unknown
    else
      do_detect_by_ldd()
    end
  end

  defp do_detect_by_ldd do
    case System.cmd("ldd", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        detect_libc_in_string(output)

      _ ->
        :unknown
    end
  rescue
    _e in ErlangError -> :unknown
  end

  defp detect_libc_in_string(output) do
    cond do
      String.match?(output, ~r/musl/i) ->
        :musl

      String.match?(output, ~r/(?:glibc|GNU.*libc|GNU C Library)/i) ->
        :gnu

      true ->
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
    musl_loaders = [
      "/lib/ld-musl-x86_64.so.1",
      "/lib/ld-musl-aarch64.so.1",
      "/lib/ld-musl-x32.so.1",
      "/lib/ld-musl-arm.so.1",
      "/lib/ld-musl-i386.so.1"
    ]

    gnu_loaders = [
      "/lib64/ld-linux-x86-64.so.2",
      "/lib/ld-linux-aarch64.so.1",
      "/lib/ld-linux-armhf.so.3",
      "/lib/ld-linux.so.2"
    ]

    cond do
      Enum.any?(musl_loaders, &File.exists?/1) -> :musl
      Enum.any?(gnu_loaders, &File.exists?/1) -> :gnu
      true -> detect_by_os_release()
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
        :gnu
    end
  end

  @spec detect_by_os_release_content(String.t()) :: libc_type()
  defp detect_by_os_release_content(content) do
    os_id = extract_os_id(content)
    os_like = extract_os_id_like(content)

    if musl_distro?(os_id, os_like) do
      :musl
    else
      :gnu
    end
  end

  defp extract_os_id(content) do
    case Regex.run(~r/^ID="?([^"\n]+)"?/im, content) do
      [_, id] -> String.downcase(id)
      _ -> ""
    end
  end

  defp extract_os_id_like(content) do
    case Regex.run(~r/^ID_LIKE="?([^"\n]+)"?/im, content) do
      [_, like] -> String.downcase(like)
      _ -> ""
    end
  end

  defp musl_distro?(os_id, os_like) do
    if os_id in @musl_distros do
      true
    else
      os_like
      |> String.split(~r/\s+/)
      |> Enum.any?(&(&1 in @musl_distros))
    end
  end

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
      String.match?(content, ~r/(?:libc\.musl|ld-musl)/) ->
        :musl

      String.match?(content, ~r/libc-(?:2|6)\./) ->
        :gnu

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

defmodule Batamanta.EnvCleaner do
  @moduledoc """
  Provides environment isolation for build commands.

  This module ensures that batamanta uses system Erlang/Elixir
  instead of version managers like asdf, mise, or kerl that can
  cause version mismatches between compile-time and runtime ERTS.

  ## The Problem

  When asdf/mise/kerl are active in the shell, they modify PATH to point
  to specific Erlang/Elixir versions. This causes:

  1. Build uses Erlang from asdf (e.g., 27.x)
  2. Runtime uses ERTS embedded by batamanta (e.g., 28.0)
  3. Binary compiled for 27.x fails on 28.x → "corrupt atom table"

  ## The Solution

  This module:
  1. Detects and filters out version manager paths from PATH
  2. Optionally uses the cached ERTS bin directory for build (ultimate consistency)
  3. Ensures build-time and runtime ERTS are exactly the same

  ## Platform Support

  Works on:
  - macOS (x86_64, aarch64)
  - Linux glibc (x86_64, aarch64)
  - Linux musl (x86_64, aarch64)
  - Windows (x86_64)
  """

  @doc """
  Returns a clean environment map that excludes asdf/mise/kerl paths.

  This function:
  - Preserves essential system variables (HOME, USER, etc.)
  - Removes asdf/mise/kerl from PATH
  - Returns a map suitable for System.cmd/3
  """
  @spec clean_env() :: %{optional(binary()) => binary() | nil}
  def clean_env do
    base_env = base_environment()
    system_path = System.get_env("PATH") || ""
    cleaned_path = clean_path(system_path)
    Map.put(base_env, "PATH", cleaned_path)
  end

  @doc """
  Returns a clean environment as a list of tuples for System.cmd/3.
  """
  @spec clean_env_tuples() :: [{binary(), binary() | nil}]
  def clean_env_tuples do
    clean_env()
    |> Map.to_list()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Returns a clean environment that uses the specified ERTS bin directory.

  This is the PREFERRED method for batamanta builds - it ensures the build
  uses exactly the same ERTS version that will be embedded in the final binary.

  ## Parameters
    - erts_path: Path to the cached ERTS directory
    - include_mix: If true, also tries to find mix in the ERTS path

  ## Returns
    Environment list tuples with:
    - PATH prepended with ERTS bin
    - ERL_AFLAGS set for proper startup
    - All version manager paths removed
  """
  @spec erts_env(Path.t(), boolean()) :: [{binary(), binary() | nil}]
  def erts_env(erts_path, include_mix \\ true) do
    erts_bin = Path.join(erts_path, "bin")

    # Find mix if available (might be in a separate location)
    mix_bin =
      if include_mix do
        find_mix_in_erts_or_system(erts_path)
      else
        nil
      end

    # Build path with ERTS bin at the front (highest priority)
    current_path = System.get_env("PATH") || ""
    cleaned_path = clean_path(current_path)

    # Prepend ERTS bin (and mix if found)
    new_path =
      case mix_bin do
        nil -> "#{erts_bin}:#{cleaned_path}"
        mix when is_binary(mix) -> "#{mix}:#{erts_bin}:#{cleaned_path}"
      end

    base_environment()
    |> Map.put("PATH", new_path)
    |> Map.put("ERL_AFLAGS", "-kernel shell_history enabled")
    |> Map.to_list()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Returns a clean environment as a map.
  """
  @spec clean_env_map() :: %{optional(binary()) => binary() | nil}
  def clean_env_map, do: clean_env()

  @doc """
  Returns the path to system Erlang executable, ignoring version managers.
  """
  @spec system_erlang_path() :: binary() | nil
  def system_erlang_path do
    system_paths()
    |> Enum.map(&Path.join(&1, "erl"))
    |> Enum.find(&File.regular?/1)
  end

  @doc """
  Returns the path to system Elixir executable, ignoring version managers.
  """
  @spec system_elixir_path() :: binary() | nil
  def system_elixir_path do
    system_paths()
    |> Enum.map(&Path.join(&1, "elixir"))
    |> Enum.find(&File.regular?/1)
  end

  @doc """
  Returns the path to system mix executable, ignoring version managers.
  """
  @spec system_mix_path() :: binary() | nil
  def system_mix_path do
    system_paths()
    |> Enum.map(&Path.join(&1, "mix"))
    |> Enum.find(&File.regular?/1)
  end

  # ============================================================================
  # PRIVATE FUNCTIONS
  # ============================================================================

  defp base_environment do
    %{
      "HOME" => System.get_env("HOME"),
      "USER" => System.get_env("USER"),
      "TMPDIR" => System.get_env("TMPDIR") || System.tmp_dir!(),
      "LANG" => System.get_env("LANG") || "en_US.UTF-8",
      "LC_ALL" => System.get_env("LC_ALL") || "en_US.UTF-8",
      "SHELL" => System.get_env("SHELL") || "/bin/sh",
      "TERM" => System.get_env("TERM") || "xterm-256color"
    }
    |> maybe_add_ssh_auth()
  end

  defp maybe_add_ssh_auth(env) do
    if sock = System.get_env("SSH_AUTH_SOCK") do
      Map.put(env, "SSH_AUTH_SOCK", sock)
    else
      env
    end
  end

  defp clean_path(current_path) do
    current_path
    |> String.split(":")
    |> Enum.reject(&version_manager_path?/1)
    |> Enum.join(":")
  end

  # Detect if a path belongs to a version manager
  defp version_manager_path?(path) do
    path_lower = String.downcase(path)

    Enum.any?([
      # asdf (all versions)
      String.contains?(path_lower, ".asdf"),
      String.contains?(path_lower, "asdf/shims"),
      # mise
      String.contains?(path_lower, ".mise"),
      String.contains?(path_lower, "mise/shims"),
      # kerl
      String.contains?(path_lower, "kerl"),
      # evm (Erlang version manager)
      String.contains?(path_lower, ".evm"),
      # goenv (for completeness)
      String.contains?(path_lower, "goenv"),
      # rbenv, pyenv, etc.
      String.contains?(path_lower, ".rbenv"),
      String.contains?(path_lower, "pyenv"),
      # nvm (Node)
      String.contains?(path_lower, "nvm"),
      # rvenv (Rust)
      String.contains?(path_lower, "rvenv")
    ])
  end

  # Common system Erlang/Elixir installation paths (platform-aware)
  defp system_paths do
    erlang_root = :code.root_dir() |> to_string()

    base_paths_for_os(:os.type(), erlang_root)
    |> Enum.flat_map(&expand_wildcards/1)
    |> Enum.reject(&version_manager_path?/1)
    |> Enum.uniq()
  end

  defp expand_wildcards(path) do
    if String.match?(path, ~r/\*/) do
      Path.wildcard(path)
    else
      [path]
    end
  end

  defp base_paths_for_os({:unix, :darwin}, erlang_root) do
    [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      Path.join(erlang_root, "bin"),
      Path.join(System.get_env("HOME") || "", "bin")
    ]
  end

  defp base_paths_for_os({:unix, :linux}, erlang_root) do
    base = [
      "/usr/bin",
      "/usr/local/bin",
      "/snap/bin",
      Path.join(erlang_root, "bin"),
      Path.join(System.get_env("HOME") || "", "bin")
    ]

    if detect_libc() == "musl" do
      base ++ ["/opt/alpine/bin"]
    else
      base
    end
  end

  defp base_paths_for_os({:win32, :nt}, erlang_root) do
    erlang_winpath = Path.join(erlang_root, "bin")
    system_drive = System.get_env("SYSTEMDRIVE") || "C:"
    prog_files = system_drive <> "\\Program Files"

    app_data =
      system_drive <> "\\Users\\" <> (System.get_env("USERNAME") || "") <> "\\AppData\\Roaming"

    [
      prog_files <> "\\erl*",
      app_data <> "\\erl*",
      erlang_winpath
    ]
  end

  defp base_paths_for_os(_, erlang_root) do
    [
      Path.join(erlang_root, "bin"),
      Path.join(System.get_env("HOME") || "", "bin")
    ]
  end

  # Detect libc type on Linux
  defp detect_libc do
    case :os.type() do
      {:unix, :linux} ->
        # Try to detect using the batamanta module if available
        try do
          # Try calling via code module for lazy loading
          case Code.ensure_loaded(Batamanta.ERTS.LibcDetector) do
            {:module, _} ->
              case Batamanta.ERTS.LibcDetector.detect() do
                :musl -> "musl"
                _ -> "gnu"
              end

            {:error, _} ->
              # Fallback: use ldd
              detect_libc_fallback()
          end
        rescue
          _ -> detect_libc_fallback()
        end

      _ ->
        "gnu"
    end
  end

  # Fallback libc detection using ldd
  defp detect_libc_fallback do
    case System.cmd("ldd", ["--version"]) do
      {output, 0} ->
        if String.contains?(output, "musl") do
          "musl"
        else
          "gnu"
        end

      _ ->
        "gnu"
    end
  end

  # Try to find mix in the downloaded ERTS, fall back to system
  defp find_mix_in_erts_or_system(erts_path) do
    # First try in ERTS bin
    mix_in_erts = Path.join(erts_path, "bin/mix")
    if File.regular?(mix_in_erts), do: mix_in_erts, else: nil
  end
end

defmodule Batamanta.EscriptPackager do
  @moduledoc """
  Packages escripts for batamanta distribution.

  This module creates a tarball containing the escript and minimal ERTS
  runtime, optimized for size. Unlike releases, escripts embed the
  Elixir runtime directly, so we only need a minimal ERTS subset.

  The payload is extracted to a `release/` directory and matches the structure
  expected by the Rust wrapper:
  ```
  payload.tar.zst
      ├── bin/
      │   └── <app_name>      # the compiled escript
      └── erts/
          ├── bin/
          │   ├── erlexec
          │   ├── erl
          │   ├── escript
          │   ├── beam.smp
          │   └── heart
          └── lib/
              └── (minimal runtime libs: kernel, stdlib, compiler)
  ```

  Escripts are typically 60-70% smaller than releases because:
  - Elixir runtime is embedded in the escript itself
  - We bundle only the minimal ERTS needed to run beam
  - No boot scripts, sys.config, or full OTP libraries

  - Uses system `tar` command for reliable archive creation
  - Uses `zstd` for high-compression final output
  - Reproducible builds with fixed ownership and timestamps
  """

  @doc """
  Packages an escript with minimal ERTS into a compressed tarball.

  - `escript_path` - Path to the compiled escript
  - `erts_path` - Path to the fetched ERTS directory (cache — never modified)
  - `output_path` - Path for the output .tar.zst file
  - `compression_level` - Zstd compression level (1-19, default: 3)

  - `{:ok, output_path}` on success
  - `{:error, reason}` on failure
  """
  @spec package(Path.t(), Path.t(), Path.t(), integer()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def package(escript_path, erts_path, output_path, compression_level \\ 3, opts \\ [])
      when is_integer(compression_level) and compression_level >= 1 and
             compression_level <= 19 do
    temp_dir = create_temp_directory()
    app_name = Path.basename(escript_path, ".escript")

    try do
      release_dir = Path.join([temp_dir, "release"])

      File.mkdir_p!(Path.join([release_dir, "bin"]))

      escript_file =
        if File.exists?(escript_path) do
          escript_path
        else
          Path.join(Path.dirname(escript_path), Path.basename(escript_path, ".escript"))
        end

      File.cp!(escript_file, Path.join([release_dir, "bin", app_name]))

      # Capture ERTS version BEFORE prepare_minimal_erts flattens
      erts_version = get_erts_version(erts_path)

      minimal_erts_path = Path.join([release_dir, "erts-#{erts_version}"])
      prepare_minimal_erts(erts_path, minimal_erts_path)

      # Copy boot files to release/bin/ so erlexec (which uses
      # $ROOTDIR/bin/ for boot file resolution via ERL_ROOTDIR)
      # can find no_dot_erlang.boot, start.boot, etc.
      copy_boot_files_to_release_bin(
        Path.join([minimal_erts_path, "bin"]),
        Path.join([release_dir, "bin"])
      )

      # Generate <app>.run entry point script
      exec_mode = Keyword.get(opts, :execution_mode, :cli)
      run_script = Batamanta.RunScript.generate(app_name, exec_mode, :escript, erts_version)
      run_script_path = Path.join([release_dir, "bin", "#{app_name}.run"])
      File.write!(run_script_path, run_script)
      File.chmod!(run_script_path, 0o755)

      tar_path = String.replace_trailing(output_path, ".tar.zst", ".tar")

      case create_tarball(temp_dir, tar_path) do
        :ok -> :ok
        {:error, _} = error -> throw(error)
      end

      case compress_zstd(tar_path, output_path, compression_level) do
        :ok -> {:ok, output_path}
        {:error, _} = error -> throw(error)
      end
    after
      File.rm_rf(temp_dir)
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  defp create_temp_directory do
    dir = Path.join(System.tmp_dir!(), "batamanta_escript_#{unique_id()}")
    File.mkdir_p!(dir)
    dir
  end

  defp unique_id do
    :erlang.unique_integer([:positive])
    |> Integer.to_string(16)
  end

  defp find_erts_bin_dir(erts_root) do
    case File.ls(erts_root) do
      {:ok, entries} ->
        erts_dir =
          Enum.find(entries, fn entry ->
            String.starts_with?(entry, "erts-") && File.dir?(Path.join(erts_root, entry))
          end)

        if erts_dir do
          Path.join([erts_root, erts_dir, "bin"])
        else
          Path.join(erts_root, "bin")
        end

      _ ->
        Path.join(erts_root, "bin")
    end
  end

  @doc """
  Prepares a minimal ERTS for escript execution by copying the necessary
  files from `erts_source` (the ERTS cache) to `erts_dest` (a temp dir).

  The cache is never modified.

  For escripts we only need:
  - The beam emulator (beam.smp or erl)
  - erlexec and escript (for escript handling)
  - Essential runtime libraries (kernel, stdlib, compiler)

  We exclude Elixir libs from the ERTS bundle because the escript file already
  embeds all Elixir code; having a stale or mismatched Elixir in the bundled
  ERTS lib/ would cause module-redefinition conflicts.
  """
  @spec prepare_minimal_erts(Path.t(), Path.t()) :: :ok
  def prepare_minimal_erts(erts_source, erts_dest) do
    File.mkdir_p!(erts_dest)

    bin_source = Path.join(erts_source, "bin")
    erts_bin_source = find_erts_bin_dir(erts_source)
    bin_dest = Path.join(erts_dest, "bin")
    File.mkdir_p!(bin_dest)

    copy_erts_binaries(erts_bin_source, bin_dest)
    copy_boot_files(bin_source, bin_dest)
    patch_erl_script(bin_dest)
    copy_erts_libs(erts_source, erts_dest)
    copy_releases_metadata(erts_source, erts_dest)

    :ok
  end

  defp copy_erts_binaries(erts_bin_source, bin_dest) do
    if File.exists?(erts_bin_source) do
      for entry <- File.ls!(erts_bin_source) do
        src = Path.join(erts_bin_source, entry)
        dest = Path.join(bin_dest, entry)
        copy_erts_entry(src, dest)
      end

      :ok
    else
      :ok
    end
  end

  defp copy_erts_entry(src, dest) do
    if File.dir?(src) do
      File.cp_r!(src, dest)
    else
      File.cp!(src, dest)
      make_executable(dest)
    end
  end

  defp copy_boot_files(bin_source, bin_dest) do
    for boot_file <- ~w(no_dot_erlang.boot start.boot start_clean.boot) do
      src = Path.join(bin_source, boot_file)

      if File.exists?(src) do
        File.cp!(src, Path.join(bin_dest, boot_file))
      end
    end

    :ok
  end

  # Patches erl script to use BINDIR="$ROOTDIR/bin" instead of
  # BINDIR="$ROOTDIR/erts-X.Y/bin". This pairs with ERL_ROOTDIR in the .run
  # script (escript format only), which sets ROOTDIR to the ERTS root dir.
  # Result: BINDIR → erts-X.Y/bin (correct location for bundled erlexec).
  defp patch_erl_script(bin_dest) do
    erl_script = Path.join(bin_dest, "erl")

    if File.exists?(erl_script) do
      content = File.read!(erl_script)

      patched =
        String.replace(
          content,
          ~r/^BINDIR="\$ROOTDIR\/erts-[^"]+\/bin"$/m,
          ~s(BINDIR="$ROOTDIR/bin")
        )

      if patched != content do
        File.write!(erl_script, patched)
      end

      :ok
    else
      :ok
    end
  end

  defp copy_erts_libs(erts_source, erts_dest) do
    lib_source = Path.join(erts_source, "lib")
    lib_dest = Path.join(erts_dest, "lib")
    File.mkdir_p!(lib_dest)

    for lib_src <- Path.wildcard(Path.join(lib_source, "*")) do
      lib_name = Path.basename(lib_src)

      unless skip_elixir_lib?(lib_name) do
        dest_lib = Path.join(lib_dest, lib_name)
        copy_minimal_lib(lib_src, dest_lib)
      end
    end

    :ok
  end

  defp skip_elixir_lib?(lib_name) do
    lib_name == "elixir" or String.starts_with?(lib_name, "elixir_")
  end

  defp copy_releases_metadata(erts_source, erts_dest) do
    releases_source = Path.join(erts_source, "releases")
    releases_dest = Path.join(erts_dest, "releases")

    if File.exists?(releases_source) do
      File.mkdir_p!(releases_dest)

      start_erl = Path.join(releases_source, "start_erl.data")

      if File.exists?(start_erl) do
        File.cp!(start_erl, Path.join(releases_dest, "start_erl.data"))
      end

      :ok
    else
      :ok
    end
  end

  defp copy_minimal_lib(src, dest) do
    File.mkdir_p!(dest)

    src_ebin = Path.join(src, "ebin")
    dest_ebin = Path.join(dest, "ebin")

    if File.exists?(src_ebin) do
      File.mkdir_p!(dest_ebin)

      for beam <- Path.wildcard(Path.join(src_ebin, "*.beam")) do
        File.cp!(beam, Path.join(dest_ebin, Path.basename(beam)))
      end

      for app <- Path.wildcard(Path.join(src_ebin, "*.app")) do
        File.cp!(app, Path.join(dest_ebin, Path.basename(app)))
      end
    end

    src_priv = Path.join(src, "priv")
    dest_priv = Path.join(dest, "priv")

    if File.exists?(src_priv) do
      File.cp_r!(src_priv, dest_priv)
    end
  end

  # Copies boot files from ERTS bin dir to release/bin/ so erlexec can
  # find them via $ROOTDIR/bin/ (used with ERL_ROOTDIR in the .run script).
  # Standard OTP has symlinks $ROOTDIR/bin/no_dot_erlang.boot →
  # ../erts-X.Y/bin/no_dot_erlang.boot; we copy them instead.
  @spec copy_boot_files_to_release_bin(Path.t(), Path.t()) :: :ok
  defp copy_boot_files_to_release_bin(erts_bin_dir, release_bin_dir) do
    for boot_file <- ~w(no_dot_erlang.boot start.boot start_clean.boot) do
      src = Path.join(erts_bin_dir, boot_file)

      if File.exists?(src) do
        File.cp!(src, Path.join(release_bin_dir, boot_file))
      end
    end

    :ok
  end

  defp make_executable(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    perms = Bitwise.band(mode, 0o777)
    new_perms = Bitwise.bor(perms, 0o111)
    new_mode = Bitwise.bor(Bitwise.band(mode, 0o77700), new_perms)
    File.chmod!(path, new_mode)
  end

  defp create_tarball(source_dir, tar_path) do
    tar_temp = String.replace_trailing(tar_path, ".tar", "_uncompressed.tar")

    {os_type, os_name} = :os.type()

    tar_opts =
      if os_type == :unix and os_name == :darwin do
        ["-C", source_dir, "-c", "-f", tar_temp, "."]
      else
        [
          "-C",
          source_dir,
          "-c",
          "-f",
          tar_temp,
          "--owner=0",
          "--group=0",
          "--mtime=1970-01-01 00:00:00",
          "."
        ]
      end

    case System.cmd("tar", tar_opts) do
      {_, 0} ->
        File.rename(tar_temp, tar_path)
        :ok

      {error, _} ->
        File.rm(tar_temp)
        {:error, "tar creation failed: #{error}"}
    end
  end

  defp compress_zstd(tar_path, output_path, level) do
    File.rm(output_path)

    case System.cmd("zstd", ["-#{level}", "-f", "-o", output_path, tar_path]) do
      {_, 0} -> :ok
      {error, _} -> {:error, "zstd compression failed: #{error}"}
    end
  end

  @doc """
  Returns the approximate size of a minimal ERTS package.
  Useful for user feedback.
  """
  @spec estimate_size(Path.t()) :: {:ok, integer()} | {:error, String.t()}
  def estimate_size(escript_path) when is_binary(escript_path) do
    with {:ok, %{size: escript_size}} <- File.stat(escript_path),
         {:ok, erts_path} <- find_erts_in_cache() do
      minimal_erts_size = estimate_minimal_erts_size(erts_path)
      {:ok, escript_size + minimal_erts_size}
    else
      {:error, _} -> {:ok, 15_000_000}
    end
  end

  defp find_erts_in_cache do
    cache_dir = Path.join([System.user_home!(), ".cache", "batamanta"])

    case File.ls(cache_dir) do
      {:ok, entries} ->
        erts_dirs = Enum.filter(entries, &String.starts_with?(&1, "erts-"))

        case erts_dirs do
          [erts_dir | _] -> {:ok, Path.join(cache_dir, erts_dir)}
          [] -> {:error, :no_erts_cached}
        end

      {:error, _} ->
        {:error, :no_cache}
    end
  end

  defp estimate_minimal_erts_size(erts_path) do
    essential_libs = ["kernel", "stdlib", "compiler"]

    Enum.reduce(essential_libs, 0, fn lib, acc ->
      lib_path = Path.join([erts_path, "lib", lib])

      if File.dir?(lib_path) do
        size = directory_size(lib_path)
        acc + div(size, 10)
      else
        acc
      end
    end) + 5_000_000
  end

  defp directory_size(dir) do
    Path.join(dir, "**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  Extracts the ERTS numeric version (e.g., `"14.2"`) from an ERTS cache
  directory by looking for the `erts-*` subdirectory.
  """
  @spec get_erts_version(Path.t()) :: String.t()
  def get_erts_version(erts_path) do
    case Path.wildcard(Path.join(erts_path, "erts-*")) do
      [dir | _] ->
        dir |> Path.basename() |> String.trim_leading("erts-")

      [] ->
        release_in_erts = find_first_subdir(Path.join(erts_path, "releases"))

        case release_in_erts do
          nil -> raise("Cannot determine ERTS version from #{erts_path}")
          dir -> dir
        end
    end
  end

  defp find_first_subdir(path) do
    with true <- File.exists?(path),
         {:ok, entries} <- File.ls(path) do
      entries
      |> Enum.find(fn entry ->
        full = Path.join(path, entry)
        File.dir?(full) and entry not in [".", ".."]
      end)
    else
      _ -> nil
    end
  end
end

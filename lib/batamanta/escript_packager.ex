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
  def package(escript_path, erts_path, output_path, compression_level \\ 3)
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
          # fallback: try without .escript extension
          Path.join(Path.dirname(escript_path), Path.basename(escript_path, ".escript"))
        end

      File.cp!(escript_file, Path.join([release_dir, "bin", app_name]))

      # FIX (Bug 1 equivalent for escript): prepare_minimal_erts previously
      # operated on erts_path directly, which could mutate the user's ERTS
      # cache. We now copy only what we need from the cache into the temp
      # release dir, never touching the cached source.
      minimal_erts_path = Path.join([release_dir, "erts"])
      prepare_minimal_erts(erts_path, minimal_erts_path)

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

  # Locate the bin directory containing erlexec/beam.smp within an OTP root.
  # OTP tarballs may nest these under an erts-X.Y/ subdirectory.
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
    # The real erlexec/beam.smp may live under erts-X.Y/bin/ in the OTP tarball.
    erts_bin_source = find_erts_bin_dir(erts_source)
    bin_dest = Path.join(erts_dest, "bin")
    File.mkdir_p!(bin_dest)

    # Copy ALL binaries from erts-X.Y/bin/ (the real ERTS binaries) into the
    # flat bin/ directory.  This matches what the release packager does via
    # flatten_nested_erts/1 and avoids fragile whack-a-mole of individual
    # files (inet_gethost, erl_child_setup, epmd, heart, etc.).
    if File.exists?(erts_bin_source) do
      for entry <- File.ls!(erts_bin_source) do
        src = Path.join(erts_bin_source, entry)
        dest = Path.join(bin_dest, entry)
        if File.dir?(src) do
          File.cp_r!(src, dest)
        else
          File.cp!(src, dest)
          make_executable(dest)
        end
      end
    end

    # Also copy boot files from the top-level bin/ (no_dot_erlang.boot,
    # start.boot, etc.) — these are NOT in erts-X.Y/bin/ but are needed
    # by escript/erlexec to start the BEAM VM.
    for boot_file <- ~w(no_dot_erlang.boot start.boot start_clean.boot) do
      src = Path.join(bin_source, boot_file)
      if File.exists?(src) do
        File.cp!(src, Path.join(bin_dest, boot_file))
      end
    end

    # Patch the erl script: its BINDIR line hardcodes $ROOTDIR/erts-X.Y/bin/
    # but batamanta flattens the ERTS directory structure (no erts-X.Y/
    # subdirectory).  Replace it so BINDIR points to the flat bin/ instead.
    erl_script = Path.join(bin_dest, "erl")
    if File.exists?(erl_script) do
      content = File.read!(erl_script)
      patched = String.replace(content, ~r/^BINDIR="\$ROOTDIR\/erts-[^"]+\/bin"$/m,
                               ~s(BINDIR="$ROOTDIR/bin"))
      if patched != content do
        File.write!(erl_script, patched)
      end
    end

    # Copy minimal OTP libs needed to boot the BEAM and run the escript.
    # NOTE: do NOT include "elixir" here. The escript already bundles its own
    # Elixir runtime; bundling another copy from the ERTS cache (which may be
    # a different Elixir version) causes "module already loaded" errors and
    # corrupt atom table crashes.
    lib_source = Path.join(erts_source, "lib")
    lib_dest = Path.join(erts_dest, "lib")
    File.mkdir_p!(lib_dest)

    # Copy all OTP libs except Elixir ones to allow runtime dependencies like :crypto, :runtime_tools.
    for lib_src <- Path.wildcard(Path.join(lib_source, "*")) do
      lib_name = Path.basename(lib_src)
      # Skip Elixir-related libs to avoid duplicate Elixir runtime
      if lib_name == "elixir" or String.starts_with?(lib_name, "elixir_") do
        :ok
      else
        dest_lib = Path.join(lib_dest, lib_name)
        copy_minimal_lib(lib_src, dest_lib)
      end
    end

    # Copy releases/ metadata so get_release_version() in Rust can read
    # the ERTS version from releases/start_erl.data if present.
    releases_source = Path.join(erts_source, "releases")
    releases_dest = Path.join(erts_dest, "releases")

    if File.exists?(releases_source) do
      File.mkdir_p!(releases_dest)

      start_erl = Path.join(releases_source, "start_erl.data")

      if File.exists?(start_erl) do
        File.cp!(start_erl, Path.join(releases_dest, "start_erl.data"))
      end
    end

    :ok
  end

  # Find a lib directory by prefix (libs may have version suffixes like kernel-9.2)
  defp find_lib_dir(lib_source, lib_name) do
    exact = Path.join(lib_source, lib_name)

    if File.exists?(exact) do
      exact
    else
      case File.ls(lib_source) do
        {:ok, entries} ->
          match =
            Enum.find(entries, fn entry ->
              entry == lib_name or String.starts_with?(entry, lib_name <> "-")
            end)

          if match, do: Path.join(lib_source, match), else: nil

        _ ->
          nil
      end
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

      # Also copy .app files
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
end

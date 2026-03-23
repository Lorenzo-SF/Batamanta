defmodule Batamanta.EscriptPackager do
  @moduledoc """
  Packages escripts for batamanta distribution.

  This module creates a tarball containing the escript and minimal ERTS
  runtime, optimized for size. Unlike releases, escripts embed the
  Elixir runtime directly, so we only need a minimal ERTS subset.

  ## Payload Structure

  The payload is extracted to a `release/` directory and matches the structure
  expected by the Rust wrapper:
  ```
  payload.tar.zst
  └── release/               # Extraction root (expected by Rust wrapper)
      ├── bin/
      │   └── <app_name>   # The compiled escript binary
      └── erts/            # Minimal ERTS (beam emulator + required libs)
          ├── bin/
          │   ├── erlexec
          │   ├── erl
          │   ├── beam.smp
          │   └── heart
          └── lib/
              └── (minimal runtime libs: kernel, stdlib, compiler, elixir)
  ```

  ## Size Optimization

  Escripts are typically 60-70% smaller than releases because:
  - Elixir runtime is embedded in the escript itself
  - We bundle only the minimal ERTS needed to run beam
  - No boot scripts, sys.config, or full OTP libraries

  ## Implementation Notes

  - Uses system `tar` command for reliable archive creation
  - Uses `zstd` for high-compression final output
  - Reproducible builds with fixed ownership and timestamps
  """

  @doc """
  Packages an escript with minimal ERTS into a compressed tarball.

  ## Parameters

  - `escript_path` - Path to the compiled escript
  - `erts_path` - Path to the fetched ERTS directory
  - `output_path` - Path for the output .tar.zst file
  - `compression_level` - Zstd compression level (1-19, default: 3)

  ## Returns

  - `{:ok, output_path}` on success
  - `{:error, reason}` on failure
  """
  @spec package(Path.t(), Path.t(), Path.t(), integer()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def package(escript_path, erts_path, output_path, compression_level \\ 3)
      when is_integer(compression_level) and compression_level >= 1 and
             compression_level <= 19 do
    temp_dir = create_temp_directory()
    app_name = Path.basename(escript_path)

    try do
      # Structure: release/ (matches what Rust wrapper expects after extraction)
      release_dir = Path.join([temp_dir, "release"])

      # 1. Copy escript to release/bin/
      File.mkdir_p!(Path.join([release_dir, "bin"]))
      File.cp!(escript_path, Path.join([release_dir, "bin", app_name]))

      # 2. Prepare minimal ERTS in release/erts/
      minimal_erts_path = Path.join([release_dir, "erts"])
      prepare_minimal_erts(erts_path, minimal_erts_path)

      # 3. Create tarball
      tar_path = String.replace_trailing(output_path, ".tar.zst", ".tar")

      case create_tarball(temp_dir, tar_path) do
        :ok -> :ok
        {:error, _} = error -> throw(error)
      end

      # 4. Compress with zstd
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

  # Creates a temporary directory for packaging
  defp create_temp_directory do
    dir = Path.join(System.tmp_dir!(), "batamanta_escript_#{unique_id()}")
    File.mkdir_p!(dir)
    dir
  end

  # Generates a unique ID
  defp unique_id do
    :erlang.unique_integer([:positive])
    |> Integer.to_string(16)
  end

  # Finds the erts-X.Y/bin directory within the ERTS cache
  # The cached ERTS has structure: erts-X.Y/bin/ for actual binaries
  defp find_erts_bin_dir(erts_root) do
    case File.ls(erts_root) do
      {:ok, entries} ->
        # Look for directory starting with "erts-"
        erts_dir =
          Enum.find(entries, fn entry ->
            String.starts_with?(entry, "erts-") && File.dir?(Path.join(erts_root, entry))
          end)

        if erts_dir do
          Path.join([erts_root, erts_dir, "bin"])
        else
          # Fallback to bin/
          Path.join(erts_root, "bin")
        end

      _ ->
        Path.join(erts_root, "bin")
    end
  end

  @doc """
  Prepares a minimal ERTS for escript execution.

  For escripts, we only need:
  - The beam emulator (beam.smp or erl)
  - erlexec (for escript handling)
  - Essential runtime libraries (kernel, stdlib, elixir)

  We exclude:
  - Documentation
  - Source files
  - Unused libraries
  - Development tools
  """
  @spec prepare_minimal_erts(Path.t(), Path.t()) :: :ok
  def prepare_minimal_erts(erts_source, erts_dest) do
    File.mkdir_p!(erts_dest)

    # ERTS structure: erts_source/bin has wrapper scripts, but actual binaries
    # (erlexec, beam.smp) are in erts_source/erts-X.Y/bin/
    # We need to search both locations
    bin_source = Path.join(erts_source, "bin")
    erts_bin_source = find_erts_bin_dir(erts_source)
    bin_dest = Path.join(erts_dest, "bin")
    File.mkdir_p!(bin_dest)

    # Essential binaries to copy
    essential_bins = [
      "erlexec",
      "erl",
      "start",
      "heart",
      "beam.smp"
    ]

    for bin <- essential_bins do
      # Try both locations: bin/ and erts-X.Y/bin/
      src = Path.join(bin_source, bin)
      src_erts_bin = Path.join(erts_bin_source, bin)

      src_path = if File.exists?(src), do: src, else: src_erts_bin

      if File.exists?(src_path) do
        dest = Path.join(bin_dest, bin)
        File.cp!(src_path, dest)
        make_executable(dest)
      end
    end

    # Copy essential libraries
    lib_source = Path.join(erts_source, "lib")
    lib_dest = Path.join(erts_dest, "lib")
    File.mkdir_p!(lib_dest)

    essential_libs = [
      "kernel",
      "stdlib",
      "compiler",
      "elixir"
    ]

    for lib <- essential_libs do
      src_lib = Path.join(lib_source, lib)

      if File.exists?(src_lib) do
        dest_lib = Path.join(lib_dest, lib)
        copy_minimal_lib(src_lib, dest_lib)
      end
    end

    # Copy releases directory for ERTS versioning
    releases_source = Path.join(erts_source, "releases")
    releases_dest = Path.join(erts_dest, "releases")

    if File.exists?(releases_source) do
      File.mkdir_p!(releases_dest)

      # Copy only start_erl.data
      start_erl = Path.join(releases_source, "start_erl.data")

      if File.exists?(start_erl) do
        File.cp!(start_erl, Path.join(releases_dest, "start_erl.data"))
      end
    end

    :ok
  end

  # Copies a library with minimal content (no docs, no src)
  defp copy_minimal_lib(src, dest) do
    File.mkdir_p!(dest)

    # Copy ebin (compiled beam files)
    src_ebin = Path.join(src, "ebin")
    dest_ebin = Path.join(dest, "ebin")

    if File.exists?(src_ebin) do
      File.mkdir_p!(dest_ebin)

      for beam <- Path.wildcard(Path.join(src_ebin, "*.beam")) do
        File.cp!(beam, Path.join(dest_ebin, Path.basename(beam)))
      end
    end

    # Copy priv if exists
    src_priv = Path.join(src, "priv")
    dest_priv = Path.join(dest, "priv")

    if File.exists?(src_priv) do
      File.cp_r!(src_priv, dest_priv)
    end
  end

  # Makes a file executable
  # Note: File.stat returns mode including file type (0o100000 for regular files)
  # We need to mask out the type bits and only add execution permissions
  defp make_executable(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    # Extract only the permission bits (last 9 bits = 0o777)
    perms = Bitwise.band(mode, 0o777)
    # Add execute permission for user, group, and others
    new_perms = Bitwise.bor(perms, 0o111)
    # Combine file type with new permissions
    new_mode = Bitwise.bor(Bitwise.band(mode, 0o77700), new_perms)
    File.chmod!(path, new_mode)
  end

  # Creates a tarball from the temp directory using system tar
  # This is more reliable than :erl_tar for complex directory structures
  defp create_tarball(source_dir, tar_path) do
    # Use tar command for reliability - create uncompressed tar first
    # then we'll compress it with zstd
    tar_temp = String.replace_trailing(tar_path, ".tar", "_uncompressed.tar")

    # Build tar options based on OS (GNU tar vs BSD tar)
    # BSD tar (macOS) doesn't support --mtime, --owner, --group
    {os_type, os_name} = :os.type()

    tar_opts =
      if os_type == :unix and os_name == :darwin do
        # BSD tar (macOS)
        ["-C", source_dir, "-c", "-f", tar_temp, "."]
      else
        # GNU tar (Linux)
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
        # Rename temp tar to final tar
        File.rename(tar_temp, tar_path)
        :ok

      {error, _} ->
        File.rm(tar_temp)
        {:error, "tar creation failed: #{error}"}
    end
  end

  # Compresses a tar file with zstd
  defp compress_zstd(tar_path, output_path, level) do
    # Delete output if exists
    File.rm(output_path)

    # Compress with zstd
    opts = if level > 9, do: ["-#{level}"], else: ["-#{level}"]

    case System.cmd("zstd", opts ++ ["-f", "-o", output_path, tar_path]) do
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
      # Default estimate: ~15MB
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
    # Rough estimate based on essential libs
    essential_libs = ["kernel", "stdlib", "compiler", "elixir"]

    # + beam.smp + erlexec (~5MB)
    Enum.reduce(essential_libs, 0, fn lib, acc ->
      lib_path = Path.join([erts_path, "lib", lib])

      if File.dir?(lib_path) do
        size = directory_size(lib_path)
        # Only count ebin (~10% of full lib)
        acc + div(size, 10)
      else
        acc
      end
    end) + 5_000_000
  end

  defp directory_size(dir) do
    dir
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

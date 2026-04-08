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

  # Find the actual ERTS version directory (e.g., erts-16.0) in the ERTS cache
  # Checks both:
  # - lib/erts-X.Y (real OTP structure)
  # - erts-X.Y (alternate structure seen in some ERTS downloads)
  defp find_erts_version_dir(erts_source) do
    # Try lib/erts-X.Y first (standard OTP structure)
    lib_path = Path.join(erts_source, "lib")
    result = find_erts_in_dir(lib_path)

    if result, do: result, else: find_erts_version_dir_root(erts_source)
  end

  # Find erts entry in a directory
  defp find_erts_in_dir(dir_path) do
    if File.dir?(dir_path) do
      case File.ls(dir_path) do
        {:ok, entries} -> find_erts_entry(entries, dir_path)
        _ -> nil
      end
    end
  end

  # Try finding erts-X.Y at root level
  defp find_erts_version_dir_root(erts_source) do
    case File.ls(erts_source) do
      {:ok, entries} -> find_erts_entry(entries, erts_source)
      _ -> nil
    end
  end

  # Find entry that starts with "erts-"
  defp find_erts_entry(entries, base_path) do
    Enum.find(entries, fn entry ->
      String.starts_with?(entry, "erts-") and File.dir?(Path.join(base_path, entry))
    end)
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

    # Determine source paths
    bin_source = Path.join(erts_source, "bin")
    erts_version_dir = find_erts_version_dir(erts_source)
    erts_bin_source = resolve_erts_bin_source(erts_source, erts_version_dir)

    # Copy binaries from both locations
    bin_dest = Path.join(erts_dest, "bin")
    File.mkdir_p!(bin_dest)
    copy_essential_bins(bin_source, erts_bin_source, bin_dest)

    # Copy ERTS lib directory if nested structure exists
    copy_erts_lib_dir(erts_source, erts_dest, erts_version_dir)

    # Copy essential libraries
    copy_essential_libs(erts_source, erts_dest)

    # Copy releases directory
    copy_releases_dir(erts_source, erts_dest)

    :ok
  end

  # Resolve the actual ERTS bin source path
  # Handles both lib/erts-X.Y/bin and erts-X.Y/bin structures
  defp resolve_erts_bin_source(erts_source, erts_version_dir) do
    if erts_version_dir do
      resolve_erts_bin_with_version(erts_source, erts_version_dir)
    else
      Path.join(erts_source, "bin")
    end
  end

  # Resolve bin path when version dir exists
  defp resolve_erts_bin_with_version(erts_source, erts_version_dir) do
    lib_erts_bin = Path.join([erts_source, "lib", erts_version_dir, "bin"])

    if File.dir?(lib_erts_bin) do
      lib_erts_bin
    else
      resolve_erts_bin_fallback(erts_source, erts_version_dir)
    end
  end

  # Fallback to root erts-X.Y/bin or root bin
  defp resolve_erts_bin_fallback(erts_source, erts_version_dir) do
    root_erts_bin = Path.join([erts_source, erts_version_dir, "bin"])

    if File.dir?(root_erts_bin) do
      root_erts_bin
    else
      Path.join(erts_source, "bin")
    end
  end

  # Copy essential binaries from both bin locations
  defp copy_essential_bins(bin_source, erts_bin_source, bin_dest) do
    essential_bins = [
      "erlexec",
      "escript",
      "erl",
      "start",
      "heart",
      "beam.smp",
      "dyn_erl"
    ]

    for bin <- essential_bins do
      src_bin = Path.join(bin_source, bin)
      src_erts_bin = Path.join(erts_bin_source, bin)
      src_path = find_first_existing([src_bin, src_erts_bin])

      if src_path do
        dest = Path.join(bin_dest, bin)
        File.cp!(src_path, dest)
        make_executable(dest)

        # Patch erl script to use relative paths instead of hardcoded paths
        if bin == "erl" do
          patch_erl_script(dest)
        end
      end
    end

    # Copy all boot and support files (critical for VM startup)
    for src <- [bin_source, erts_bin_source],
        file <- Path.wildcard(Path.join(src, "*.{boot,script,config}")),
        not File.dir?(file) do
      dest = Path.join(bin_dest, Path.basename(file))
      unless File.exists?(dest), do: File.cp!(file, dest)
    end

    # Also copy any other binaries from erts_bin_source
    copy_additional_bins(erts_bin_source, bin_dest)
  end

  # Patch erl script to use relative paths
  # The original script has hardcoded paths like: BINDIR="$ROOTDIR/erts-16.0/bin"
  # We change it to use relative paths from the script's location
  defp patch_erl_script(path) do
    # Overwrite erl script with a clean, relocatable version
    # Our structure: release/erts/bin/erl and release/erts/bin/erlexec
    # So BINDIR is the script directory, and ROOTDIR is its parent.
    content = """
    #!/bin/sh
    # Batamanta relocatable erl wrapper
    SELF_PATH=$(cd "$(dirname "$0")" && pwd)
    export BINDIR="$SELF_PATH"
    export ROOTDIR=$(cd "$SELF_PATH/.." && pwd)
    export EMU=beam
    export PROGNAME=$(basename "$0")
    exec "$BINDIR/erlexec" "$@"
    """

    File.write!(path, content)
  end

  # Find first existing path from list
  defp find_first_existing(paths) do
    Enum.find(paths, &File.exists?/1)
  end

  # Copy additional binaries from ERTS bin directory
  defp copy_additional_bins(erts_bin_source, bin_dest) do
    if File.dir?(erts_bin_source) do
      entries = File.ls!(erts_bin_source)
      copy_additional_bins_entries(entries, erts_bin_source, bin_dest)
    end
  end

  # Copy each additional binary
  defp copy_additional_bins_entries(entries, erts_bin_source, bin_dest) do
    for entry <- entries do
      src = Path.join(erts_bin_source, entry)
      dest = Path.join(bin_dest, entry)

      if File.regular?(src) and not File.exists?(dest) do
        File.cp!(src, dest)
        make_executable(dest)
      end
    end
  end

  # Copy the ERTS lib directory (e.g., lib/erts-16.0 or erts-16.0)
  defp copy_erts_lib_dir(_erts_source, _erts_dest, nil), do: :ok

  defp copy_erts_lib_dir(erts_source, erts_dest, erts_version_dir) do
    # Try lib/erts-X.Y first
    src_erts_lib = Path.join([erts_source, "lib", erts_version_dir])
    dest_erts_lib = Path.join([erts_dest, "lib", erts_version_dir])

    if File.dir?(src_erts_lib) do
      File.mkdir_p!(Path.dirname(dest_erts_lib))
      File.cp_r!(src_erts_lib, dest_erts_lib)
    else
      # Try root-level: erts-X.Y
      src_root_erts = Path.join([erts_source, erts_version_dir])
      dest_root_erts = Path.join([erts_dest, "lib", erts_version_dir])

      if File.dir?(src_root_erts) do
        File.mkdir_p!(Path.dirname(dest_root_erts))
        File.cp_r!(src_root_erts, dest_root_erts)
      end
    end
  end

  # Copy essential libraries
  defp copy_essential_libs(erts_source, erts_dest) do
    lib_dest = Path.join(erts_dest, "lib")
    File.mkdir_p!(lib_dest)

    # 1. Copiar librerías de Erlang desde el ERTS descargado
    erlang_lib_source = Path.join(erts_source, "lib")

    if File.dir?(erlang_lib_source) do
      case File.ls(erlang_lib_source) do
        {:ok, entries} ->
          erlang_prefixes = [
            "kernel",
            "stdlib",
            "compiler",
            "runtime_tools",
            "crypto",
            "asn1",
            "public_key",
            "ssl",
            "syntax_tools",
            "xmerl",
            "tools",
            "parsetools"
          ]

          for entry <- entries do
            if Enum.any?(erlang_prefixes, &prefix_matches?(&1, entry)) do
              src_lib = Path.join(erlang_lib_source, entry)
              dest_lib = Path.join(lib_dest, entry)
              copy_minimal_lib(src_lib, dest_lib)
            end
          end

        _ ->
          :ok
      end
    end

    # 2. Bundle Elixir Core Libs desde el sistema (son BEAMs portátiles)
    # Esto es CRÍTICO para que el binario sea 100% autocontenido y no dependa
    # de si el host tiene Elixir instalado o no.
    elixir_apps = [:elixir, :logger, :mix, :eex, :iex]

    for app <- elixir_apps do
      case :code.lib_dir(app) do
        path when is_list(path) ->
          src_path = List.to_string(path)
          dest_path = Path.join(lib_dest, Path.basename(src_path))

          unless File.exists?(dest_path) do
            copy_minimal_lib(src_path, dest_path)
          end

        path when is_binary(path) ->
          dest_path = Path.join(lib_dest, Path.basename(path))

          unless File.exists?(dest_path) do
            copy_minimal_lib(path, dest_path)
          end

        _ ->
          :ok
      end
    end
  end

  defp prefix_matches?(prefix, entry) do
    entry == prefix or String.starts_with?(entry, "#{prefix}-")
  end

  # Copy releases directory for ERTS versioning
  defp copy_releases_dir(erts_source, erts_dest) do
    releases_source = Path.join(erts_source, "releases")
    releases_dest = Path.join(erts_dest, "releases")

    if File.exists?(releases_source) do
      File.mkdir_p!(releases_dest)
      copy_release_files(releases_source, releases_dest)
    end
  end

  # Copy all release files
  defp copy_release_files(releases_source, releases_dest) do
    for file <- Path.wildcard(Path.join(releases_source, "*")) do
      dest = Path.join(releases_dest, Path.basename(file))

      if File.dir?(file) do
        File.cp_r!(file, dest)
      else
        File.cp!(file, dest)
      end
    end
  end

  # Copies a library with minimal content (no docs, no src)
  defp copy_minimal_lib(src, dest) do
    File.mkdir_p!(dest)

    src_ebin = Path.join(src, "ebin")
    dest_ebin = Path.join(dest, "ebin")

    if File.exists?(src_ebin) do
      File.mkdir_p!(dest_ebin)
      File.cp_r!(src_ebin, dest_ebin)
    end

    src_priv = Path.join(src, "priv")
    dest_priv = Path.join(dest, "priv")

    if File.exists?(src_priv) do
      File.mkdir_p!(dest_priv)
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

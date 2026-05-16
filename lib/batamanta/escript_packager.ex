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
          ├── bin/
          │   ├── erlexec
          │   ├── erl
          │   ├── beam.smp
          │   └── heart
          └── lib/
              └── (minimal runtime libs: kernel, stdlib, compiler, elixir)
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
  - `erts_path` - Path to the fetched ERTS directory
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

    bin_source = Path.join(erts_source, "bin")
    erts_bin_source = find_erts_bin_dir(erts_source)
    bin_dest = Path.join(erts_dest, "bin")
    File.mkdir_p!(bin_dest)

    essential_bins = [
      "erlexec",
      "erl",
      "start",
      "heart",
      "beam.smp"
    ]

    for bin <- essential_bins do
      src = Path.join(bin_source, bin)
      src_erts_bin = Path.join(erts_bin_source, bin)

      src_path = if File.exists?(src), do: src, else: src_erts_bin

      if File.exists?(src_path) do
        dest = Path.join(bin_dest, bin)
        File.cp!(src_path, dest)
        make_executable(dest)
      end
    end

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

  defp copy_minimal_lib(src, dest) do
    File.mkdir_p!(dest)

    src_ebin = Path.join(src, "ebin")
    dest_ebin = Path.join(dest, "ebin")

    if File.exists?(src_ebin) do
      File.mkdir_p!(dest_ebin)

      for beam <- Path.wildcard(Path.join(src_ebin, "*.beam")) do
        File.cp!(beam, Path.join(dest_ebin, Path.basename(beam)))
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
    essential_libs = ["kernel", "stdlib", "compiler", "elixir"]

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

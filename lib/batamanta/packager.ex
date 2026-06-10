defmodule Batamanta.Packager do
  @moduledoc """
  Handles creation of the compressed payload tarball.

  Packages the Elixir release and ERTS into a single Zstandard-compressed
  tarball that will be embedded in the final binary.


  - **Relativization**: Converts absolute paths in release scripts to relative
  - **Cleanup**: Removes non-essential files (src, docs, misc)
  - **Boot File Preparation**: Ensures correct .boot file for target platform
  """

  @doc """
  Packages the release and the ERTS into a single compressed tarball.

    - `rel_path` - Path to the Mix release directory
    - `erts_path` - Path to the fetched ERTS directory
    - `out_path` - Path for the output compressed tarball
    - `compression_level` - Zstandard compression level (1-19)

    - `{:ok, path}` - Success with output path
    - `{:error, reason}` - Failure with error message
  """
  @spec package(Path.t(), Path.t(), Path.t(), integer()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def package(rel_path, erts_path, out_path, compression_level) do
    temp = Path.join(System.tmp_dir!(), "bat_pkg_#{:erlang.unique_integer([:positive])}")
    app_name = Mix.Project.config()[:app] |> to_string()

    try do
      File.mkdir_p!(temp)
      tar_path = Path.join(temp, "payload.tar")

      erts_work_path = Path.join(temp, "erts_work")
      File.mkdir_p!(erts_work_path)
      File.cp_r!(erts_path, erts_work_path)
      erts_work = erts_work_path

      prepare_erts(erts_work)

      app_name
      |> then(&prepare_start_boot(rel_path, &1, erts_work))

      relativize_release_scripts(rel_path)
      remove_mix_bundled_erts(rel_path, erts_work)
      update_start_erl_data(rel_path, erts_work)

      files = collect_files(rel_path, erts_work, "release", "release/erts")

      case :erl_tar.create(String.to_charlist(tar_path), files) do
        :ok ->
          compress_with_zstd(tar_path, out_path, compression_level)

        {:error, reason} ->
          {:error, "Tar creation failed: #{inspect(reason)}"}
      end
    after
      File.rm_rf!(temp)
    end
  end

  # ============================================================================
  # ERTS PREPARATION (operates on the working copy, never on the cache)
  # ============================================================================

  @spec prepare_erts(Path.t()) :: :ok
  defp prepare_erts(erts_path) do
    flatten_nested_erts(erts_path)
    cleanup_erts(erts_path)
    ensure_executable_permissions(erts_path)
  end

  defp flatten_nested_erts(erts_path) do
    nested_erts = Path.wildcard(Path.join(erts_path, "erts-*"))

    Enum.each(nested_erts, fn nested_dir ->
      nested_bin = Path.join(nested_dir, "bin")
      nested_erts_dir = Path.join(nested_dir, "erts")

      if File.exists?(nested_bin) do
        File.cp_r!(nested_bin, Path.join(erts_path, "bin"))
      end

      if File.exists?(nested_erts_dir) do
        dest_erts = Path.join(erts_path, "erts")
        File.mkdir_p!(dest_erts)
        File.cp_r!(nested_erts_dir, dest_erts)
      end

      File.rm_rf!(nested_dir)
    end)

    :ok
  end

  @spec cleanup_erts(Path.t()) :: :ok
  defp cleanup_erts(erts_path) do
    paths_to_remove = [
      Path.join(erts_path, "src"),
      Path.join(erts_path, "docs"),
      Path.join(erts_path, "misc"),
      Path.join(erts_path, Path.join("releases", "MANIFEST"))
    ]

    Enum.each(paths_to_remove, &remove_if_exists/1)

    lib_path = Path.join(erts_path, "lib")

    if File.exists?(lib_path) do
      Path.wildcard(Path.join(lib_path, "*"))
      |> Enum.each(&cleanup_lib_dir/1)
    end

    :ok
  end

  defp remove_if_exists(path) do
    if File.exists?(path), do: File.rm_rf(path)
  end

  defp cleanup_lib_dir(lib_dir) do
    remove_if_exists(Path.join(lib_dir, "src"))
    remove_if_exists(Path.join(lib_dir, "doc"))
  end

  @spec ensure_executable_permissions(Path.t()) :: :ok
  defp ensure_executable_permissions(erts_path) do
    bin_dirs = [
      Path.join(erts_path, "bin"),
      Path.join(erts_path, Path.join("erts", Path.join("*", "bin")))
    ]

    Enum.each(bin_dirs, fn pattern ->
      pattern
      |> Path.wildcard()
      |> Enum.flat_map(&files_in_dir/1)
      |> Enum.each(&ensure_executable/1)
    end)

    :ok
  end

  defp files_in_dir(dir) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "*"))
    else
      [dir]
    end
  end

  defp ensure_executable(file) do
    with false <- File.dir?(file),
         {:ok, stat} <- File.stat(file),
         :regular <- stat.type do
      add_execute_permissions(file, stat.mode)
    end

    :ok
  end

  defp add_execute_permissions(file, current_mode) do
    new_mode = Bitwise.bor(current_mode, 0o111)

    if new_mode != current_mode do
      File.chmod(file, new_mode)
    end
  end

  # ============================================================================
  # BOOT FILE PREPARATION
  # ============================================================================

  @spec prepare_start_boot(Path.t(), String.t(), Path.t()) :: :ok
  defp prepare_start_boot(rel_path, app_name, erts_work) do
    rel_path_abs = Path.absname(rel_path)
    bin_path = Path.join(rel_path_abs, "bin")

    version = read_release_version(rel_path_abs)
    version_dir = Path.join([rel_path_abs, "releases", version])

    primary_dst = Path.join(version_dir, "start.boot")
    secondary_dst = Path.join(bin_path, "start.boot")

    boot_source = find_best_boot(rel_path_abs, bin_path, app_name)

    case boot_source do
      nil ->
        :ok

      src ->
        unless File.exists?(primary_dst) do
          File.mkdir_p!(version_dir)
          File.cp!(src, primary_dst)
        end

        unless File.exists?(secondary_dst) do
          File.mkdir_p!(bin_path)
          File.cp!(src, secondary_dst)
        end

        ensure_sys_config(rel_path_abs, version_dir, erts_work)
        ensure_vm_args(rel_path_abs, version_dir)
    end

    :ok
  end

  defp read_release_version(rel_path_abs) do
    start_erl = Path.join([rel_path_abs, "releases", "start_erl.data"])

    if File.exists?(start_erl) do
      case String.split(File.read!(start_erl), " ", trim: true) do
        [_erts, version | _] -> String.trim(version)
        _ -> fallback_release_version(rel_path_abs)
      end
    else
      fallback_release_version(rel_path_abs)
    end
  end

  defp fallback_release_version(rel_path_abs) do
    releases_dir = Path.join(rel_path_abs, "releases")

    case File.ls(releases_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in ["COOKIE", "start_erl.data"]))
        |> Enum.filter(&File.dir?(Path.join(releases_dir, &1)))
        |> List.first("0.1.0")

      _ ->
        "0.1.0"
    end
  end

  defp find_best_boot(rel_path_abs, bin_path, app_name) do
    releases_path = Path.join(rel_path_abs, "releases")

    boot_files =
      [bin_path, releases_path]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.boot")))
      |> Enum.reject(&String.contains?(&1, "start_clean"))
      |> Enum.sort_by(&boot_priority(&1, app_name))

    List.first(boot_files)
  end

  @spec boot_priority(String.t(), String.t()) :: integer()
  defp boot_priority(path, app_name) do
    cond do
      String.contains?(path, "#{app_name}.boot") -> 0
      String.contains?(path, "start.boot") -> 1
      true -> 2
    end
  end

  defp ensure_sys_config(rel_path_abs, version_dir, _erts_work) do
    dst = Path.join(version_dir, "sys.config")

    unless File.exists?(dst) do
      found =
        Path.wildcard(Path.join([rel_path_abs, "releases", "**", "sys.config"]))
        |> List.first()

      if found do
        File.cp!(found, dst)
      else
        File.mkdir_p!(version_dir)
        File.write!(dst, "[].\\n")
      end
    end
  end

  defp ensure_vm_args(rel_path_abs, version_dir) do
    dst = Path.join(version_dir, "vm.args")

    unless File.exists?(dst) do
      found =
        Path.wildcard(Path.join([rel_path_abs, "releases", "**", "vm.args"]))
        |> List.first()

      if found do
        File.cp!(found, dst)
      else
        File.mkdir_p!(version_dir)
        File.write!(dst, "-noshell\n")
      end
    end
  end

  # ============================================================================
  # MIX BUNDLED ERTS REMOVAL
  # ============================================================================

  defp remove_mix_bundled_erts(rel_path, erts_work) do
    erts_version = extract_erts_version(erts_work)

    if erts_version do
      mix_erts_path = Path.join(rel_path, "erts-#{erts_version}")

      if File.exists?(mix_erts_path) do
        File.rm_rf!(mix_erts_path)
      end
    else
      rel_path
      |> Path.join("erts-*")
      |> Path.wildcard()
      |> Enum.each(&File.rm_rf!/1)
    end
  end

  defp update_start_erl_data(rel_path, erts_work) do
    start_erl_path = Path.join([rel_path, "releases", "start_erl.data"])

    if File.exists?(start_erl_path) do
      erts_version = extract_erts_version(erts_work)
      releases_dir = Path.join(rel_path, "releases")

      app_vsn =
        releases_dir
        |> File.ls!()
        |> Enum.filter(
          &(&1 != "COOKIE" && &1 != "start_erl.data" && File.dir?(Path.join(releases_dir, &1)))
        )
        |> List.first()

      if erts_version && app_vsn do
        new_content = "#{erts_version} #{app_vsn}"
        File.write!(start_erl_path, new_content)
      end
    end
  end

  # ============================================================================
  # SCRIPT RELATIVIZATION
  # ============================================================================

  @spec relativize_release_scripts(Path.t()) :: :ok
  defp relativize_release_scripts(rel_path) do
    rel_path_abs = Path.absname(rel_path)

    bin_scripts =
      rel_path_abs
      |> Path.join("bin")
      |> Path.join("*")
      |> Path.wildcard()

    Enum.each(bin_scripts, &relativize_bin_script/1)

    version_scripts =
      Path.wildcard(Path.join(rel_path_abs, "releases") <> "/*/*.script") ++
        Path.wildcard(Path.join(rel_path_abs, "releases") <> "/*/*.boot")

    Enum.each(version_scripts, &relativize_script/1)

    :ok
  end

  defp relativize_bin_script(script) do
    if File.regular?(script) do
      content = File.read!(script)
      relativized = relativize_content(content)

      if relativized != content do
        File.write!(script, relativized)
      end
    end
  end

  defp relativize_content(content) do
    content
  end

  defp relativize_script(script) do
    with true <- File.regular?(script),
         content when is_binary(content) <- File.read!(script),
         true <- String.printable?(content) do
      do_relative_replace(script, content)
    end

    :ok
  end

  defp do_relative_replace(script, content) do
    relativized = String.replace(content, ~r/\$ROOTDIR/, ~s"$RELEASE_ROOT")

    if relativized != content do
      File.write!(script, relativized)
    end
  end

  # ============================================================================
  # FILE COLLECTION
  # ============================================================================

  @spec collect_files(Path.t(), Path.t(), String.t(), String.t()) :: [
          {charlist(), charlist()}
        ]
  defp collect_files(rel_path, erts_path, rel_prefix, erts_prefix) do
    rel_path_abs = Path.absname(rel_path)
    erts_path_abs = Path.absname(erts_path)

    rel_files =
      Path.wildcard(Path.join(rel_path_abs, "**/*"))
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(fn path ->
        rel = Path.relative_to(path, rel_path_abs)
        archive_name = Path.join(rel_prefix, rel)
        {String.to_charlist(archive_name), String.to_charlist(path)}
      end)

    erts_files =
      Path.wildcard(Path.join(erts_path_abs, "**/*"))
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(fn path ->
        rel = Path.relative_to(path, erts_path_abs)
        archive_name = Path.join(erts_prefix, rel)
        {String.to_charlist(archive_name), String.to_charlist(path)}
      end)

    rel_files ++ erts_files
  end

  # ============================================================================
  # COMPRESSION
  # ============================================================================

  @spec compress_with_zstd(Path.t(), Path.t(), integer()) ::
          {:ok, Path.t()} | {:error, String.t()}
  defp compress_with_zstd(tar, zst, level) do
    ensure_zstd_available!()

    case System.cmd("zstd", ["-z", "-f", "--rm", "-#{level}", tar, "-o", zst],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        {:ok, zst}

      {err, code} ->
        {:error, "Zstd failed (exit code #{code}): #{err}"}
    end
  end

  defp ensure_zstd_available! do
    unless System.find_executable("zstd") do
      raise """
      zstd is required but not installed.

      Install with:
        sudo apt install zstd

        brew install zstd

        apk add zstd

      """
    end
  end

  defp extract_erts_version(erts_path) do
    releases_path = Path.join(erts_path, "releases")

    with true <- File.exists?(releases_path),
         {:ok, entries} <- File.ls(releases_path) do
      entries
      |> Enum.find(fn entry ->
        full = Path.join(releases_path, entry)
        File.dir?(full) and entry not in [".", ".."]
      end)
    else
      _ -> nil
    end
  end
end

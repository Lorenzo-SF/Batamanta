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
    config = Mix.Project.config()
    app_name = config[:app] |> to_string()

    try do
      File.mkdir_p!(temp)
      tar_path = Path.join(temp, "payload.tar")

      erts_work_path = Path.join(temp, "erts_work")
      File.mkdir_p!(erts_work_path)
      File.cp_r!(erts_path, erts_work_path)
      erts_work = erts_work_path

      # Capture ERTS version BEFORE prepare_erts modifies the structure
      erts_version = get_erts_version(erts_work)

      prepare_erts(erts_work)

      app_name
      |> then(&prepare_start_boot(rel_path, &1, erts_work))

      relativize_release_scripts(rel_path)
      remove_mix_bundled_erts(rel_path, erts_work)
      update_start_erl_data(rel_path, erts_work)

      # Generate <app>.run entry point script
      bata_config = Keyword.get(config, :batamanta, [])
      exec_mode = Keyword.get(bata_config, :execution_mode, :cli)
      run_script = Batamanta.RunScript.generate(app_name, exec_mode, :release, erts_version)
      run_script_path = Path.join([rel_path, "bin", "#{app_name}.run"])
      File.write!(run_script_path, run_script)
      File.chmod!(run_script_path, 0o755)

      # ERTS goes at the same level as the release. No subdirectory prefix
      # — this keeps erlexec's ROOTDIR resolution correct and avoids the
      # need for --boot-var ROOTDIR overrides in bin/<app>.
      files = collect_files(rel_path, erts_work, "release", "release")

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
    # The ERTS cache has the standard OTP structure:
    #   <erts_path>/erts-X.Y/bin/   ← VM binaries (erlexec, beam.smp)
    #   <erts_path>/lib/            ← OTP libs (kernel, stdlib)
    #   <erts_path>/bin/            ← Shell tools (erl, escript, boot files)
    #
    # We keep this structure intact — no flattening needed. The ERTS is
    # packed alongside the release at the same level, so erlexec can
    # compute ROOTDIR correctly from its own path, boot scripts resolve
    # $ROOTDIR/lib/kernel-* to the right location, and no script patching
    # is required.
    cleanup_erts(erts_path)
    ensure_executable_permissions(erts_path)
  end

  @spec cleanup_erts(Path.t()) :: :ok
  defp cleanup_erts(erts_path) do
    # Remove ERTS src/docs/misc — not needed at runtime
    paths_to_remove = [
      Path.join(erts_path, "src"),
      Path.join(erts_path, "docs"),
      Path.join(erts_path, "misc")
    ]

    Enum.each(paths_to_remove, &remove_if_exists/1)

    # Remove ERTS releases/ — it conflicts with the release's own releases/
    # at the same path in the payload. The release has the correct boot scripts,
    # sys.config, and start_erl.data.
    erts_releases = Path.join(erts_path, "releases")
    remove_if_exists(erts_releases)

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
      Path.join(erts_path, "erts-*/bin")
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

    Enum.each(bin_scripts, fn script ->
      relativize_bin_script(script)
      patch_bin_app_for_bundled_erlexec(script)
    end)

    version_scripts =
      Path.wildcard(Path.join(rel_path_abs, "releases") <> "/*/*.script") ++
        Path.wildcard(Path.join(rel_path_abs, "releases") <> "/*/*.boot")

    Enum.each(version_scripts, &relativize_script/1)

    :ok
  end

  # ============================================================================
  # bin/<app> PATCHES FOR BUNDLED erlexec
  # ============================================================================

  # Patches the `bin/<app>` shell script to work with the bundled erlexec.
  #
  # The only patch needed is:
  #
  # 1. `--boot-var ROOT "$RELEASE_ROOT"` added after `--boot-var RELEASE_LIB`.
  #    The boot script uses `$ROOT` for OTP app paths (kernel, stdlib). Without
  #    this override, erlexec computes ROOT from its own path
  #    (`release/erts-X.Y/`), but OTP libs are at `release/lib/kernel-*`.
  #
  # `--erl-config` does NOT need patching — the bundled `releases/<vsn>/elixir`
  # script already handles it correctly by converting to `-config` for erl.
  #
  @spec patch_bin_app_for_bundled_erlexec(Path.t()) :: :ok
  defp patch_bin_app_for_bundled_erlexec(script) do
    if File.regular?(script) do
      content = File.read!(script)

      # Skip escripts — they have no bin/<app> shell script
      if String.contains?(content, "--erl-config") do
        patched = patch_boot_var_root(content)
        File.write!(script, patched)
      end
    end

    :ok
  end

  # Ensure --boot-var ROOT "$RELEASE_ROOT" is present after --boot-var RELEASE_LIB.
  # The boot script uses $ROOT for OTP app paths (kernel, stdlib). erlexec
  # computes ROOT from its own path (release/erts-X.Y/), but OTP libs are
  # at release/lib/kernel-*. This override makes $ROOT point to the release
  # root instead.
  #
  # Also removes the old (incorrect) --boot-var ROOTDIR "$RELEASE_ROOT/erts"
  # that was added by previous versions of batamanta.
  #
  # Idempotent: skips if --boot-var ROOT is already present anywhere in the
  # script (e.g., from a previous run of this patch).
  @spec patch_boot_var_root(String.t()) :: String.t()
  defp patch_boot_var_root(content) do
    if String.contains?(content, "--boot-var ROOT ") do
      content
    else
      # Replace: RELEASE_LIB line + optional old ROOTDIR line
      #   → RELEASE_LIB line + new ROOT line with trailing backslash
      String.replace(
        content,
        ~r/(--boot-var RELEASE_LIB "\$RELEASE_ROOT\/lib" \\\n)(?:\s*--boot-var ROOTDIR "\$RELEASE_ROOT\/erts"\n)?/,
        "\\1        --boot-var ROOT \"$RELEASE_ROOT\" \\\n"
      )
    end
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

  @doc """
  Extracts the ERTS numeric version (e.g., `"14.2"`) from an ERTS work
  directory by looking for the `erts-*` subdirectory.

  Must be called BEFORE `prepare_erts/1` flattens the structure.
  """
  @spec get_erts_version(Path.t()) :: String.t()
  def get_erts_version(erts_path) do
    case Path.wildcard(Path.join(erts_path, "erts-*")) do
      [dir | _] ->
        dir |> Path.basename() |> String.trim_leading("erts-")

      [] ->
        # Fallback: try to read from the top-level releases/ directory
        case extract_erts_version(erts_path) do
          nil -> raise "Cannot determine ERTS version from #{erts_path}"
          otp_ver -> otp_ver
        end
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

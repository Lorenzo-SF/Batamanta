defmodule Batamanta.Packager do
  @moduledoc """
  Handles creation of the compressed payload tarball.

  Packages the Elixir release and ERTS into a single Zstandard-compressed
  tarball that will be embedded in the final binary.


  - **Relativization**: Converts absolute paths in release scripts to relative
  - **Cleanup**: Removes non-essential files (src, docs, misc)
  - **Boot File Preparation**: Ensures correct .boot file for target platform
  """

  alias Batamanta.DaemonConfig

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
    bata_config = Keyword.get(config, :batamanta, [])

    # The daemon is compiled BEFORE `mix release` by mix batamanta's
    # execute_release_pipeline (see compile_daemon_for_build/4), so the
    # compiled .beam + .app already exist under _build/prod/lib/ and
    # get picked up automatically when `mix release` runs. The compiled
    # .app ends up in rel_path/lib/ without further intervention, and
    # the payload tar below includes rel_path/lib/** as part of files.
    #
    # We still validate the daemon config here so callers see the same
    # error messages they used to get from Daemon.compile/4 inside the
    # try/rescue boundary.
    _daemon_config =
      bata_config
      |> Keyword.get(:daemon)
      |> DaemonConfig.from_config()
      |> DaemonConfig.with_resolved_user_app()

    try do
      File.mkdir_p!(temp)
      tar_path = Path.join(temp, "payload.tar")

      erts_work_path = Path.join(temp, "erts_work")
      File.mkdir_p!(erts_work_path)
      File.cp_r!(erts_path, erts_work_path)
      erts_work = erts_work_path

      # Capture ERTS version BEFORE prepare_erts modifies the structure.
      # We pass both `erts_path` (the Fetcher cache dir, whose name follows
      # the `erts-<vsn>-<platform_key>` convention) AND `erts_work`
      # (the flattened work area). Layout-1/2 detectors read `erts_work`
      # only; the cache-name fallback reads `erts_path` only — useful
      # for upstream erlang/otp Windows `.zip` prebuilts which ship as a
      # flat root with no `erts-*/`, no `releases/<vsn>/`, no OTP_VERSION
      # anywhere on disk.
      erts_version = get_erts_version(erts_work, erts_path)

      prepare_erts(erts_work)

      app_name
      |> then(&prepare_start_boot(rel_path, &1, erts_work))

      relativize_release_scripts(rel_path)
      remove_mix_bundled_erts(rel_path, erts_work, erts_path)
      update_start_erl_data(rel_path, erts_work, erts_path)

      # The BEAM daemon (when enabled) is compiled BEFORE `mix release`
      # at `_build/prod/lib/batamanta_daemon-0.1.0/` so that Mix
      # recognises it as a regular OTP application. After release
      # assembly, the daemon's .beam files are already inside
      # `rel_path/lib/batamanta_daemon-0.1.0/ebin/` and we just need
      # to include them in the payload tar. No re-compilation here.

      # Generate <app>.run entry point script
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
          Batamanta.Compression.compress(:zstd, tar_path, out_path, compression_level)

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

  defp remove_mix_bundled_erts(rel_path, erts_work, erts_path \\ erts_work) do
    erts_version = detect_erts_version(erts_work, erts_path)

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

  defp update_start_erl_data(rel_path, erts_work, erts_path \\ erts_work) do
    start_erl_path = Path.join([rel_path, "releases", "start_erl.data"])

    if File.exists?(start_erl_path) do
      erts_version = detect_erts_version(erts_work, erts_path)
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

  # Compression is delegated to `Batamanta.Compression`; the
  # packager now supports any backend the compression layer
  # implements (zstd by default, gzip and none as fallbacks).
  # See `Batamanta.Compression` for the magic-bytes detection
  # that lets the Rust dispenser pick the right decompressor.

  @doc """
  Extracts the ERTS numeric version (e.g., `"14.2"` or `"28"`) from an ERTS
  cache or work directory.

  ## Layouts supported

  The Fetcher handles three upstream tarball/zip layouts (see
  `Batamanta.ERTS.Fetcher.erts_valid?/2` for the validator):

    1. **Linux/Mac release-style**: `<root>/erts-<vsn>/bin/erlexec` exists.
    2. **Windows release-style**: `<root>/bin/erl.exe` + `<root>/releases/<vsn>/`.
    3. **Windows raw-style** (some erlang/otp Windows prebuilt zips):
       `erl.exe`, `start.boot` etc. all at the root — no `erts-<vsn>/` subdir.

  Layouts 1 and 2 are picked up by the `erts-<vsn>/` glob. Layout 3 needs
  a fallback to `<root>/releases/<vsn>/OTP_VERSION` (file) or
  `<root>/releases/<vsn>/start_erl.data` (parses "OTPVSN PRODVSN").

  ## Why this matters for Windows

  `Path.wildcard(Path.join(erts_path, "erts-*"))` is the original detection
  mechanism but it only matches layout 1/2. On Windows, layout 3 (no
  `erts-<vsn>/` subdir) is the one some prebuilt zips actually use, so
  `mix batamanta` on Windows would raise `Cannot determine ERTS version`
  even though the cache is valid.

  ## Returns

  A string like `"28"` or `"14.2"`. Raises with a descriptive message if
  no layout matches.
  """
  @spec get_erts_version(Path.t()) :: String.t()
  def get_erts_version(erts_path), do: get_erts_version(erts_path, erts_path)

  @spec get_erts_version(Path.t(), Path.t()) :: String.t()
  def get_erts_version(erts_work, erts_path) do
    case detect_erts_version(erts_work, erts_path) do
      nil ->
        raise "Cannot determine ERTS version from #{erts_work} " <>
                "(no erts-* subdir, no releases/<vsn>/ subdir, " <>
                "no releases/<vsn>/OTP_VERSION, no releases/<vsn>/start_erl.data, " <>
                "no erts-<vsn>-<platform_key> cache name recoverable)"

      version ->
        version
    end
  end

  @doc """
  Like `get_erts_version/1` but returns `nil` instead of raising when no
  layout matches. Used by helpers like `remove_mix_bundled_erts/2` and
  `update_start_erl_data/2` that want to fall back to a glob-based
  cleanup rather than abort the whole packager run.
  """
  @spec detect_erts_version(Path.t()) :: String.t() | nil
  def detect_erts_version(erts_path), do: detect_erts_version(erts_path, erts_path)

  @spec detect_erts_version(Path.t(), Path.t()) :: String.t() | nil
  def detect_erts_version(erts_work, erts_path) do
    detect_from_erts_subdir(erts_work) ||
      detect_from_releases_subdir(erts_work) ||
      detect_from_otp_version_file(erts_work) ||
      detect_from_start_erl_data(erts_work) ||
      detect_from_cache_dir_name(erts_path)
  end

  # Layout 3 fallback 2: the parent of <erts_path> carries the cache
  # directory name "erts-<vsn>-<platform_key>" (Fetcher's convention).
  # We can't help with layouts that lack the version internally AND
  # whose cache name was renamed out of the convention, but in every
  # Fetcher-produced cache dir this name preserves the original
  # `otp_version` argument verbatim, so we can recover the version
  # without needing any file inside <erts_path>.
  #
  # This is what makes a Windows prebuilt zip (root-only files,
  # no `erts-*/releases/` tree at all) usable: the upstream
  # Erlang/OTP Windows .zip does not embed the OTP version anywhere
  # on disk, so the layout-1/2 detectors all miss. The cache-name
  # fallback is the only thing standing between the user and the
  # `Cannot determine ERTS version` raised by `get_erts_version/1`.
  defp detect_from_cache_dir_name(erts_path) do
    case Path.basename(erts_path) do
      "erts-" <> rest ->
        case String.split(rest, "-", parts: 2) do
          [vsn, _platform] when is_binary(vsn) ->
            if valid_otp_version_string?(vsn), do: vsn, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # Layout 1/2: a directory named `erts-<vsn>/` exists at the root.
  # We use `File.ls/1` + filter rather than `Path.wildcard/1` because:
  #   * Wildcard treats backslashes vs forward slashes inconsistently
  #     on Windows when the input path mixes separators (which the
  #     BatPkg temp dirs frequently do).
  #   * Wildcard returns files too on some platforms; we want only
  #     directories and only those whose name starts with `erts-`.
  #
  # The `<vsn>` suffix MUST be a numeric OTP version (e.g. "14.2", "28").
  # This is critical because the Fetcher's cache directory is also named
  # `erts-<otp_version>-<platform_key>` (e.g. `erts-28.5-windows-amd64`).
  # The packager does `File.cp_r!(erts_cache, erts_work)` before calling
  # get_erts_version/1, so `erts_work` contains the cache directory as a
  # subdirectory. Without the `valid_otp_version_string?/1` check the
  # cascade would happily return "28.5-windows-amd64" as if it were a
  # version, breaking every packager run on Windows (and any other
  # platform whose cache directory name starts with `erts-` and gets
  # sorted before the upstream `erts-<X.Y>` runtime dir).
  defp detect_from_erts_subdir(erts_path) do
    with {:ok, entries} <- File.ls(erts_path),
         [dir | _] <-
           Enum.filter(entries, fn e ->
             String.starts_with?(e, "erts-") and
               File.dir?(Path.join(erts_path, e)) and
               valid_otp_version_string?(
                 e |> String.trim_leading("erts-")
               )
           end) do
      dir |> String.trim_leading("erts-")
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Layout 1/2/3: a directory under `<root>/releases/` whose name looks
  # like an OTP version (e.g. `28`, `28.0`, `28.0.1`). The directory
  # typically contains `start_erl.data` and `OTP_VERSION`.
  defp detect_from_releases_subdir(erts_path) do
    releases_path = Path.join(erts_path, "releases")

    with {:ok, entries} <- File.ls(releases_path),
         [dir | _] <-
           Enum.filter(entries, fn e ->
             File.dir?(Path.join(releases_path, e)) and
               e not in [".", ".."] and
               valid_otp_version_string?(e)
           end) do
      dir
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Layout 3 (Windows raw): a top-level `releases/<vsn>/OTP_VERSION` file.
  # The file content is the OTP release tag (e.g. "28" or "28.0.1") — we
  # trim and return it. The `Batamanta.RunScript` consumer of this value
  # only needs the major.minor prefix to construct `erts-<X.Y>` paths,
  # so we collapse "X.Y.Z" to "X.Y" for consistency with layout 1/2.
  defp detect_from_otp_version_file(erts_path) do
    case find_releases_subdir(erts_path) do
      nil ->
        nil

      version ->
        path =
          erts_path
          |> Path.join("releases")
          |> Path.join(version)
          |> Path.join("OTP_VERSION")

        case File.read(path) do
          {:ok, content} -> content |> String.trim() |> normalise_otp_vsn()
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp normalise_otp_vsn(vsn) do
    case String.split(vsn, ".") do
      [major] -> major
      [major, minor | _] -> "#{major}.#{minor}"
      _ -> nil
    end
  end

  # Layout 3 fallback: `releases/<vsn>/start_erl.data` has the form
  # "OTPVSN PRODVSN\n" (newline-terminated). We split on whitespace and
  # return the first token.
  defp detect_from_start_erl_data(erts_path) do
    case find_releases_subdir(erts_path) do
      nil ->
        nil

      version ->
        path = Path.join([erts_path, "releases", version, "start_erl.data"])
        parse_start_erl_data_file(path)
    end
  rescue
    _ -> nil
  end

  defp parse_start_erl_data_file(path) do
    case File.read(path) do
      {:ok, content} -> first_token(content)
      _ -> nil
    end
  end

  defp first_token(content) do
    case String.split(String.trim(content)) do
      [first | _] -> first
      _ -> nil
    end
  end

  defp find_releases_subdir(erts_path) do
    releases_path = Path.join(erts_path, "releases")

    with {:ok, entries} <- File.ls(releases_path),
         [dir | _] <-
           Enum.filter(entries, fn e ->
             File.dir?(Path.join(releases_path, e)) and
               e not in [".", ".."]
           end) do
      dir
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # An OTP version is one of:
  #   * "X"     — major only (e.g. "28")
  #   * "X.Y"   — major.minor (e.g. "28.0")
  #   * "X.Y.Z" — major.minor.patch (e.g. "28.0.1")
  # We accept all three so we don't accidentally pick a non-version
  # directory like "start_erl.data" or ".DS_Store".
  #
  # We require Integer.parse/1 to consume the WHOLE segment (i.e. the
  # remainder tuple must be empty). `Integer.parse("28-windows-amd64")`
  # returns `{28, "-windows-amd64"}` — not `:error` — so a naive
  # `!= :error` check would accept the Fetcher cache directory name
  # `erts-28-windows-amd64` after `trim_leading("erts-")` and silently
  # produce a wrong version. See the Windows ERTS-detection bug
  # regression in test/batamanta/packager_test.exs.
  defp valid_otp_version_string?(s) do
    case String.split(s, ".") do
      [n] -> parse_consumes_whole?(n)
      [n1, n2] -> parse_consumes_whole?(n1) and parse_consumes_whole?(n2)
      [n1, n2, n3] -> parse_consumes_whole?(n1) and parse_consumes_whole?(n2) and parse_consumes_whole?(n3)
      _ -> false
    end
  end

  defp parse_consumes_whole?(segment) do
    case Integer.parse(segment) do
      {_int, ""} -> true
      _ -> false
    end
  end
end

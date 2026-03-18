defmodule Batamanta.ERTS.Fetcher do
  @moduledoc """
  Responsible for downloading and managing ERTS (Erlang Runtime System) cache.

  Flow:
  1. Auto-detect platform (or use specified target)
  2. Download MANIFEST.json from remote URL (with local cache)
  3. If download fails, use local MANIFEST.json from priv/
  4. Look up ERTS URL in MANIFEST for the OTP version and platform
  5. Download and extract ERTS

  ## Version Resolution Modes

  - `:explicit` (user-specified) - Uses exact version match only. Fails if not found.
  - `:auto` (auto-detected) - Uses conservative fallback (28.0 → 28.1 → ...)

  ## Platform Detection

  Auto-detects: OS (linux/macos/windows), Architecture (x86_64/aarch64), Libc (gnu/musl)
  """

  alias Batamanta.ERTS.LibcDetector

  @manifest_url "https://raw.githubusercontent.com/Lorenzo-SF/Batamanta---ERTS-repository/main/MANIFEST.json"
  @cache_dir_name "batamanta"
  @manifest_cache_key {:batamanta_erts_manifest, :loaded}

  @type otp_version :: String.t()
  @type version_mode :: :explicit | :auto

  @doc """
  Fetches ERTS for the specified OTP version.

  ## Parameters
    - `otp_version` - OTP version string (e.g., "28.0", "27.3.4")
    - `target` - Optional target. Can be:
      - `nil` - Auto-detect platform
      - `:auto` - Same as nil
      - A target map with: os, arch, libc
    - `opts` - Optional keyword list:
      - `:version_mode` - `:explicit` (exact match only) or `:auto` (fallback)

  ## Examples

      {:ok, erts_path} = Batamanta.ERTS.Fetcher.fetch("28.0")
      {:ok, erts_path} = Batamanta.ERTS.Fetcher.fetch("28.0", os: "linux", arch: "x86_64", libc: "gnu")
      {:ok, erts_path} = Batamanta.ERTS.Fetcher.fetch("28.0", :ubuntu_22_04_x86_64, version_mode: :explicit)
  """
  @spec fetch(otp_version(), map() | atom() | nil, keyword()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def fetch(otp_version, target \\ nil, opts \\ [])

  def fetch(otp_version, nil, opts) do
    fetch(otp_version, detect_platform(), opts)
  end

  def fetch(otp_version, :auto, opts) do
    fetch(otp_version, detect_platform(), opts)
  end

  def fetch(otp_version, target, opts) when is_atom(target) do
    platform = target_atom_to_platform(target)
    fetch(otp_version, platform, opts)
  end

  def fetch(otp_version, target, opts) when is_map(target) do
    version_mode = Keyword.get(opts, :version_mode, :auto)
    otp_vsn = normalize_otp_version(otp_version)
    platform_key = build_platform_key(target)

    log_info(">> Fetching ERTS for OTP #{otp_vsn} (#{platform_key})...")

    # Check cache first
    case check_erts_cache(otp_vsn, platform_key) do
      {:ok, cached_path} ->
        log_info(">> ✅ ERTS cached at: #{cached_path}")
        {:ok, cached_path}

      :not_found ->
        # Not in cache, need to download MANIFEST and possibly ERTS
        fetch_erts_with_manifest(otp_vsn, platform_key, version_mode)
    end
  end

  defp fetch_erts_with_manifest(otp_vsn, platform_key, version_mode) do
    case find_erts_url(otp_vsn, platform_key, version_mode) do
      nil when version_mode == :explicit ->
        log_error(">> ❌ ERTS version '#{otp_vsn}' not found in MANIFEST (explicit mode)")
        {:error, "ERTS version '#{otp_vsn}' not found in MANIFEST for platform '#{platform_key}'"}

      nil ->
        log_info(">> ERTS not found in MANIFEST, using system ERTS")
        {:ok, system_erts_path()}

      erts_url ->
        log_info(">> Found ERTS URL: #{erts_url}")
        download_and_extract(erts_url, otp_vsn, platform_key)
    end
  end

  defp check_erts_cache(otp_version, platform_key) do
    extract_dir = Path.join(get_cache_dir(), "erts-#{otp_version}-#{platform_key}")
    legacy_dir = Path.join(get_cache_dir(), platform_key)

    cond do
      # Check primary cache location
      File.exists?(extract_dir) and erts_valid?(extract_dir, otp_version) ->
        {:ok, extract_dir}

      # Check legacy cache location
      File.exists?(legacy_dir) and erts_valid?(legacy_dir, otp_version) ->
        {:ok, legacy_dir}

      # Not in cache
      true ->
        :not_found
    end
  end

  @doc """
  Returns the platform detected from the current system.
  """
  @spec detect_platform() :: map()
  def detect_platform do
    with {:ok, os_type} <- detect_os_type(),
         {:ok, arch} <- detect_architecture(),
         {:ok, libc} <- detect_libc(os_type) do
      %{os: os_type, arch: arch, libc: libc}
    else
      {:error, reason} ->
        raise "Could not detect platform: #{reason}"
    end
  end

  @doc """
  Returns the platform detected from the current system as an atom (for backwards compatibility).
  """
  @spec detect_host_target() :: {:ok, atom()} | {:error, String.t()}
  def detect_host_target do
    platform = detect_platform()
    {:ok, string_to_target_atom(platform)}
  end

  @doc """
  Returns the download URL for the specified OTP version and target.
  """
  @spec build_download_url(otp_version(), atom()) :: String.t()
  def build_download_url(otp_version, target) do
    platform = target_atom_to_platform(target)
    otp_vsn = normalize_otp_version(otp_version)
    platform_key = build_platform_key(platform)

    case find_erts_url(otp_vsn, platform_key) do
      nil -> "N/A (using system ERTS)"
      url -> url
    end
  end

  @doc """
  Converts a target atom (e.g., `:ubuntu_22_04_x86_64`) to a platform map.
  """
  @spec target_atom_to_platform(atom()) :: map()
  def target_atom_to_platform(target), do: target_atom_to_platform_impl(target)

  # Platform to target atom (for backwards compatibility with Target module)
  defp string_to_target_atom(%{os: "linux", arch: "x86_64", libc: libc})
       when libc in ["gnu", :gnu],
       do: :ubuntu_22_04_x86_64

  defp string_to_target_atom(%{os: "linux", arch: "x86_64", libc: libc})
       when libc in ["musl", :musl],
       do: :alpine_3_19_x86_64

  defp string_to_target_atom(%{os: "linux", arch: "aarch64", libc: libc})
       when libc in ["gnu", :gnu],
       do: :ubuntu_22_04_arm64

  defp string_to_target_atom(%{os: "linux", arch: "aarch64", libc: libc})
       when libc in ["musl", :musl],
       do: :alpine_3_19_arm64

  defp string_to_target_atom(%{os: "macos", arch: "x86_64", libc: _libc}), do: :macos_12_x86_64
  defp string_to_target_atom(%{os: "macos", arch: "aarch64", libc: _libc}), do: :macos_12_arm64
  defp string_to_target_atom(%{os: "windows", arch: "x86_64", libc: _libc}), do: :windows_x86_64

  # Target atom to platform (for backwards compatibility)
  defp target_atom_to_platform_impl(:ubuntu_22_04_x86_64),
    do: %{os: "linux", arch: "x86_64", libc: "gnu"}

  defp target_atom_to_platform_impl(:alpine_3_19_x86_64),
    do: %{os: "linux", arch: "x86_64", libc: "musl"}

  defp target_atom_to_platform_impl(:ubuntu_22_04_arm64),
    do: %{os: "linux", arch: "aarch64", libc: "gnu"}

  defp target_atom_to_platform_impl(:alpine_3_19_arm64),
    do: %{os: "linux", arch: "aarch64", libc: "musl"}

  defp target_atom_to_platform_impl(:macos_12_x86_64),
    do: %{os: "macos", arch: "x86_64", libc: nil}

  defp target_atom_to_platform_impl(:macos_12_arm64),
    do: %{os: "macos", arch: "aarch64", libc: nil}

  defp target_atom_to_platform_impl(:windows_x86_64),
    do: %{os: "windows", arch: "x86_64", libc: nil}

  defp target_atom_to_platform_impl(_), do: %{os: "linux", arch: "x86_64", libc: "gnu"}

  @doc """
  Returns the user's cache directory for Batamanta.
  """
  @spec get_cache_dir() :: Path.t()
  def get_cache_dir do
    :filename.basedir(:user_cache, @cache_dir_name) |> Path.expand()
  end

  @doc """
  Returns the path to the system ERTS.
  """
  @spec system_erts_path() :: Path.t()
  def system_erts_path do
    :code.root_dir() |> to_string()
  end

  # ============================================================================
  # MANIFEST LOADING
  # ============================================================================

  defp load_manifest do
    # Check in-memory cache first to avoid repeated downloads
    case Process.get(@manifest_cache_key) do
      nil ->
        # Not cached, load from disk or remote
        manifest = load_manifest_from_source()
        Process.put(@manifest_cache_key, manifest)
        manifest

      cached ->
        # Return cached manifest
        cached
    end
  end

  defp load_manifest_from_source do
    cached_path = Path.join(get_cache_dir(), "MANIFEST.json")
    local_path = local_manifest_path()

    # First, try to download from remote
    log_info(">>    Downloading MANIFEST.json from remote...")

    case download_manifest() do
      {:ok, body} ->
        # Save to cache for future use
        File.mkdir_p!(get_cache_dir())
        File.write!(cached_path, body)
        parse_json(body)

      {:error, _reason} ->
        # Remote download failed, try fallbacks
        log_info(">>    Download failed, using local MANIFEST.json")

        cond do
          # Try cached copy first
          File.exists?(cached_path) ->
            log_info(">>    Using cached MANIFEST.json from disk")
            File.read!(cached_path) |> parse_json()

          # Try local priv/ fallback
          File.exists?(local_path) ->
            log_info(">>    Using priv/ fallback MANIFEST.json")
            File.read!(local_path) |> parse_json()

          # No manifest available
          true ->
            log_info(">>    No MANIFEST.json available, using empty manifest")
            %{}
        end
    end
  end

  # ============================================================================
  # JSON PARSING - Using Jason if available, fallback to manual parser
  # ============================================================================

  # Try to use Jason if available (recommended)
  if Code.ensure_loaded?(Jason) do
    defp parse_json(json_string) do
      case Jason.decode(json_string) do
        {:ok, manifest} -> manifest
        {:error, _} -> %{}
      end
    end
  else
    # Fallback: Manual parser that actually works correctly
    defp parse_json(json_string) do
      json_string
      |> parse_json_object()
      |> Enum.into(%{})
    end

    defp parse_json_object(json) do
      json
      |> String.trim()
      |> String.replace("\n", "")
      |> String.replace(" ", "")
      |> extract_key_values()
      |> Enum.filter(&match?({key, _} when is_binary(key) and byte_size(key) > 0, &1))
    end

    defp extract_key_values(json) do
      # Find all "KEY": "VALUE" or "KEY": { ... } patterns
      regex = ~r/"([^"]+)"\s*:\s*("(?:[^"\\]|\\.)*"|\{[^}]*\})/

      Regex.scan(regex, json)
      |> Enum.map(fn [_full, key, value] ->
        {key, parse_json_value(value)}
      end)
    end

    defp parse_json_value("{" <> rest) do
      # Nested object
      ("{" <> rest)
      |> String.trim_trailing("}")
      |> extract_key_values()
      |> Enum.into(%{})
    end

    defp parse_json_value(value) do
      # String value - remove quotes
      value
      |> String.trim("\"")
    end
  end

  defp local_manifest_path do
    :code.priv_dir(:batamanta) |> to_string() |> Path.join("erts_repository/MANIFEST.json")
  end

  defp download_manifest do
    ensure_started([:inets, :ssl])

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(@manifest_url), []},
           [timeout: 30_000, ssl: ssl_opts],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Finds the ERTS download URL for the specified OTP version and platform key.

  ## Version Modes
  - `:explicit` - Returns exact match only, no fallbacks
  - `:auto` - Uses conservative fallback strategy
  """
  @spec find_erts_url(otp_version(), String.t(), version_mode()) :: String.t() | nil
  def find_erts_url(otp_version, platform_key, version_mode \\ :auto) do
    manifest = load_manifest()

    case version_mode do
      :explicit ->
        # Exact match only - user specified, user owns
        exact_key = "OTP-#{otp_version}"
        find_erts_in_manifest(manifest, exact_key, platform_key)

      :auto ->
        # Conservative fallback - try 28.0, 28.1, etc.
        version_variants = generate_version_variants(otp_version)

        Enum.find_value(version_variants, fn otp_key ->
          find_erts_in_manifest(manifest, otp_key, platform_key)
        end)
    end
  end

  defp find_erts_in_manifest(manifest, otp_key, platform_key) do
    if is_map(manifest) && Map.has_key?(manifest, otp_key) do
      otp_entry = Map.get(manifest, otp_key)

      if is_map(otp_entry) && Map.has_key?(otp_entry, platform_key) do
        log_info(">>    Found ERTS for #{otp_key}")
        Map.get(otp_entry, platform_key)
      else
        nil
      end
    else
      nil
    end
  end

  # ============================================================================
  # VERSION RESOLUTION
  # ============================================================================

  defp generate_version_variants(version) do
    parts = String.split(version, ".")

    variants =
      case parts do
        # Version mayor only: "28" -> try 28.0, 28.1, 28.2, etc.
        [major] ->
          Enum.flat_map(0..5, fn minor ->
            ["OTP-#{major}.#{minor}.0", "OTP-#{major}.#{minor}"]
          end)

        # Version mayor.minor: "28.1" -> try exact, then 28.0
        [major, minor] ->
          minor_int = try_parse_integer(minor)
          base = ["OTP-#{major}.#{minor}", "OTP-#{major}.#{minor}.0"]
          # Add fallbacks for earlier minor versions
          fallbacks =
            for m <- Enum.max([minor_int - 1, 0])..0//-1 do
              ["OTP-#{major}.#{m}.0", "OTP-#{major}.#{m}"]
            end

          Enum.concat([base, fallbacks])

        # Version mayor.minor.patch: "28.1.1" -> try exact, then 28.1, then 28.0
        [major, minor, patch] ->
          minor_int = try_parse_integer(minor)
          patch_int = try_parse_integer(patch)

          exact = ["OTP-#{version}"]

          # Same minor, different patch (only if patch > 0)
          same_minor =
            if patch_int > 0,
              do: for(p <- (patch_int - 1)..0//-1, do: "OTP-#{major}.#{minor}.#{p}"),
              else: []

          # Different minor, patch 0
          different_minor =
            for m <- Enum.max([minor_int - 1, 0])..0//-1 do
              ["OTP-#{major}.#{m}.0", "OTP-#{major}.#{m}"]
            end

          Enum.concat([exact, same_minor, different_minor])
      end

    ["OTP-#{version}" | variants]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
  end

  defp try_parse_integer(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> 0
    end
  end

  # ============================================================================
  # PLATFORM DETECTION
  # ============================================================================

  defp detect_os_type do
    case :os.type() do
      {:unix, :darwin} -> {:ok, "macos"}
      {:win32, _} -> {:ok, "windows"}
      {:unix, :linux} -> {:ok, "linux"}
      {family, _} -> {:error, "Unsupported OS: #{inspect(family)}"}
    end
  end

  defp detect_architecture do
    arch_str = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.contains?(arch_str, "aarch64") or String.contains?(arch_str, "arm64") ->
        {:ok, "aarch64"}

      String.contains?(arch_str, "x86_64") or String.contains?(arch_str, "amd64") ->
        {:ok, "x86_64"}

      true ->
        {:error, "Unsupported architecture: #{arch_str}"}
    end
  end

  defp detect_libc("macos"), do: {:ok, nil}
  defp detect_libc("windows"), do: {:ok, nil}

  defp detect_libc("linux") do
    {:ok, LibcDetector.detect()}
  end

  @doc """
  Builds the platform key string from a platform map.
  Examples: "amd64-glibc", "amd64-musl", "darwin-arm64", etc.
  """
  @spec build_platform_key(map()) :: String.t() | nil
  def build_platform_key(%{os: os, arch: arch, libc: libc}) do
    libc_str = to_string(libc)

    case {os, arch, libc_str} do
      {"linux", "x86_64", "gnu"} -> "amd64-glibc"
      {"linux", "x86_64", "musl"} -> "amd64-musl"
      {"linux", "aarch64", "gnu"} -> "arm64-glibc"
      {"linux", "aarch64", "musl"} -> "arm64-musl"
      {"macos", "x86_64", _} -> "darwin-amd64"
      {"macos", "aarch64", _} -> "darwin-arm64"
      {"windows", "x86_64", _} -> "windows-amd64"
      _ -> nil
    end
  end

  # ============================================================================
  # DOWNLOAD AND EXTRACTION
  # ============================================================================

  defp download_and_extract(url, otp_version, platform_key) do
    extract_dir = Path.join(get_cache_dir(), "erts-#{otp_version}-#{platform_key}")
    cache_filename = "erts-#{otp_version}-#{platform_key}.tar.gz"
    cache_path = Path.join(get_cache_dir(), cache_filename)

    log_info(">>    Downloading ERTS...")

    case download_file(url, cache_path) do
      :ok ->
        extract_erts(cache_path, extract_dir, otp_version)

      {:error, reason} ->
        {:error, "Download failed: #{reason}"}
    end
  end

  defp extract_erts(cache_path, extract_dir, otp_version) do
    File.mkdir_p!(extract_dir)

    # Use system tar instead of :erl_tar to avoid Ubuntu 24.04 symlink restrictions
    # System tar with --no-same-owner works reliably across platforms
    {output, exit_code} =
      System.cmd(
        "tar",
        [
          "-xzf",
          cache_path,
          "-C",
          extract_dir,
          "--no-same-owner"
        ],
        stderr_to_stdout: true
      )

    result =
      if exit_code == 0 do
        :ok
      else
        {:error, "tar command failed: #{output}"}
      end

    case result do
      :ok ->
        if erts_valid?(extract_dir, otp_version) do
          {:ok, extract_dir}
        else
          File.rm_rf(extract_dir)
          {:error, "ERTS validation failed"}
        end

      {:error, reason} ->
        File.rm_rf(extract_dir)
        {:error, "Tar extraction failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Failed to extract: #{inspect(e)}"}
  end

  defp download_file(url, cache_path) do
    ensure_started([:inets, :ssl])

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 120_000, ssl: ssl_opts],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        save_file(body, cache_path)

      {:ok, {{_, 404, _}, _, _}} ->
        {:error, "File not found (404)"}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP error: #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp save_file(body, cache_path) do
    tmp_path = cache_path <> ".part"

    case File.write(tmp_path, body) do
      :ok ->
        case File.rename(tmp_path, cache_path) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(tmp_path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # ERTS VALIDATION
  # ============================================================================

  defp erts_valid?(extract_dir, otp_version) do
    # More robust validation - check multiple indicators
    checks = [
      # 1. bin/erlexec exists (critical for starting VM)
      File.exists?(Path.join(extract_dir, "bin/erlexec")),
      # 2. releases/<version>/OTP_VERSION exists
      File.exists?(Path.join(extract_dir, "releases/#{otp_version}/OTP_VERSION")),
      # 3. releases/ directory with some version exists
      has_valid_release_dir?(extract_dir),
      # 4. lib/ directory exists (BEAM libraries)
      File.dir?(Path.join(extract_dir, "lib"))
    ]

    # Require at least bin/erlexec AND one other indicator
    Enum.member?(checks, true) and Enum.count(checks, & &1) >= 2
  end

  defp has_valid_release_dir?(extract_dir) do
    releases_path = Path.join(extract_dir, "releases")

    case File.ls(releases_path) do
      {:ok, versions} ->
        # Check if any version directory has OTP_VERSION file
        Enum.any?(versions, fn version ->
          File.exists?(Path.join(releases_path, version <> "/OTP_VERSION"))
        end)

      _ ->
        false
    end
  end

  defp normalize_otp_version(version) do
    parts = String.split(version, ".")

    case parts do
      [major] ->
        major

      [major, minor] ->
        "#{major}.#{minor}"

      [major, minor, patch] ->
        if(patch == "0", do: "#{major}.#{minor}", else: "#{major}.#{minor}.#{patch}")
    end
  end

  defp ensure_started(apps) do
    Enum.each(apps, &Application.ensure_all_started/1)
  end

  defp log_info(msg) do
    ctx = Process.get(:batamanta_banner_ctx)

    if ctx do
      Batamanta.Logger.info(ctx, msg)
    else
      Mix.shell().info(msg)
    end
  end

  defp log_error(msg) do
    ctx = Process.get(:batamanta_banner_ctx)

    if ctx do
      Batamanta.Logger.error(ctx, msg)
    else
      Mix.shell().error(msg)
    end
  end
end

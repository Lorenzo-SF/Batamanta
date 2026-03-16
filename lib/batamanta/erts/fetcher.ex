defmodule Batamanta.ERTS.Fetcher do
  @moduledoc """
  Responsible for downloading and managing ERTS (Erlang Runtime System) cache.

  Flow:
  1. Auto-detect platform (or use specified target)
  2. Download MANIFEST.json from remote URL (with local cache)
  3. If download fails, use local MANIFEST.json from priv/
  4. Look up ERTS URL in MANIFEST for the OTP version and platform
  5. Download and extract ERTS

  ## Platform Detection

  Auto-detects: OS (linux/macos/windows), Architecture (x86_64/aarch64), Libc (gnu/musl)
  """

  alias Batamanta.ERTS.LibcDetector

  @manifest_url "https://raw.githubusercontent.com/Lorenzo-SF/Batamanta---ERTS-repository/main/MANIFEST.json"
  @cache_dir_name "batamanta"
  @manifest_cache_key {:batamanta_erts_manifest, :loaded}

  @type otp_version :: String.t()

  @doc """
  Fetches ERTS for the specified OTP version.

  ## Parameters
    - `otp_version` - OTP version string (e.g., "28.0", "27.3.4")
    - `target` - Optional target. Can be:
      - `nil` - Auto-detect platform
      - `:auto` - Same as nil
      - A target map with: os, arch, libc

  ## Examples

      {:ok, erts_path} = Batamanta.ERTS.Fetcher.fetch("28.0")
      {:ok, erts_path} = Batamanta.ERTS.Fetcher.fetch("28.0", os: "linux", arch: "x86_64", libc: "gnu")
  """
  @spec fetch(otp_version(), map() | atom() | nil) :: {:ok, Path.t()} | {:error, String.t()}
  def fetch(otp_version, target \\ nil)

  def fetch(otp_version, nil) do
    fetch(otp_version, detect_platform())
  end

  def fetch(otp_version, :auto) do
    fetch(otp_version, detect_platform())
  end

  def fetch(otp_version, target) when is_atom(target) do
    platform = target_atom_to_platform(target)
    fetch(otp_version, platform)
  end

  def fetch(otp_version, target) when is_map(target) do
    otp_vsn = normalize_otp_version(otp_version)
    platform_key = build_platform_key(target)

    log_info(">> Fetching ERTS for OTP #{otp_vsn} (#{platform_key})...")

    # CRÍTICO: Primero verificar si el ERTS ya está en caché
    # Si está en caché y es la versión correcta, usarlo sin descargar nada
    case check_erts_cache(otp_vsn, platform_key) do
      {:ok, cached_path} ->
        log_info(">> ✅ ERTS cached at: #{cached_path}")
        {:ok, cached_path}

      :not_found ->
        # No está en caché, necesitamos descargar el MANIFEST y posiblemente el ERTS
        fetch_erts_with_manifest(otp_vsn, platform_key)
    end
  end

  defp fetch_erts_with_manifest(otp_vsn, platform_key) do
    case find_erts_url(otp_vsn, platform_key) do
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
  defp target_atom_to_platform(:ubuntu_22_04_x86_64),
    do: %{os: "linux", arch: "x86_64", libc: "gnu"}

  defp target_atom_to_platform(:alpine_3_19_x86_64),
    do: %{os: "linux", arch: "x86_64", libc: "musl"}

  defp target_atom_to_platform(:ubuntu_22_04_arm64),
    do: %{os: "linux", arch: "aarch64", libc: "gnu"}

  defp target_atom_to_platform(:alpine_3_19_arm64),
    do: %{os: "linux", arch: "aarch64", libc: "musl"}

  defp target_atom_to_platform(:macos_12_x86_64), do: %{os: "macos", arch: "x86_64", libc: nil}
  defp target_atom_to_platform(:macos_12_arm64), do: %{os: "macos", arch: "aarch64", libc: nil}
  defp target_atom_to_platform(:windows_x86_64), do: %{os: "windows", arch: "x86_64", libc: nil}
  defp target_atom_to_platform(_), do: %{os: "linux", arch: "x86_64", libc: "gnu"}

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

  defp parse_json(json_string) do
    json_string
    |> String.trim()
    |> String.replace("{", "")
    |> String.replace("}", "")
    |> String.split(",")
    |> Enum.reduce(%{}, &parse_manifest_item/2)
  end

  defp parse_manifest_item(item, acc) do
    case String.split(item, ":", parts: 2) do
      [key, value] ->
        clean_key = String.trim(key) |> String.replace(~r/^"|"$/, "")
        clean_value = String.trim(value) |> String.replace(~r/^"|"$/, "")

        if String.starts_with?(clean_key, "OTP-") do
          Map.put(acc, clean_key, parse_platform_entry(clean_value))
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp parse_platform_entry(entry) do
    entry
    |> String.replace("{", "")
    |> String.replace("}", "")
    |> String.split(",")
    |> Enum.reduce(%{}, fn item, acc ->
      case String.split(item, ":", parts: 2) do
        [key, value] ->
          clean_key = String.trim(key) |> String.replace(~r/^"|"$/, "")
          clean_value = String.trim(value) |> String.replace(~r/^"|"$/, "")
          Map.put(acc, clean_key, clean_value)

        _ ->
          acc
      end
    end)
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

  defp find_erts_url(otp_version, platform_key) do
    manifest = load_manifest()

    version_variants = generate_version_variants(otp_version)

    Enum.find_value(version_variants, fn otp_key ->
      find_erts_in_manifest(manifest, otp_key, platform_key)
    end)
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

  defp generate_version_variants(version) do
    parts = String.split(version, ".")

    variants =
      case parts do
        [major] ->
          [
            "OTP-#{major}.0",
            "OTP-#{major}.1",
            "OTP-#{major}.2",
            "OTP-#{major}.3",
            "OTP-#{major}.4"
          ]

        [major, minor] ->
          ["OTP-#{major}.#{minor}.0", "OTP-#{major}.#{minor}"]

        [_major, _minor, _patch] ->
          ["OTP-#{version}"]
      end

    ["OTP-#{version}" | variants]
    |> Enum.uniq()
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

  defp build_platform_key(%{os: os, arch: arch, libc: libc}) do
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

    result =
      :erl_tar.extract(cache_path, [:compressed, {:cwd, extract_dir}])

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

  defp erts_valid?(extract_dir, otp_version) do
    erts_bin = Path.join(extract_dir, "bin/erlexec")
    erts_version_file_1 = Path.join(extract_dir, "releases/#{otp_version}/OTP_VERSION")
    otp_dir = String.replace(otp_version, ~r/\.0$/, "")
    erts_version_file_2 = Path.join(extract_dir, "releases/#{otp_dir}/OTP_VERSION")

    File.exists?(erts_bin) or File.exists?(erts_version_file_1) or
      File.exists?(erts_version_file_2)
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
end

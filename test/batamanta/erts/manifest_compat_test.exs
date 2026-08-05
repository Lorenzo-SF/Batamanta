defmodule Batamanta.ERTS.ManifestCompatTest do
  @moduledoc """
  Cross-validates Batamanta's `Target.manifest_key/1` against the actual
  MANIFEST.json published in `Lorenzo-SF/Batamanta---ERTS-repository`.

  This is the safety net that catches the most common breakage: a new
  target is added to `Batamanta.Target` but the asset name in the upstream
  mirror is different (or the mirror's build pipeline doesn't ship that
  target yet). Without this test the Fetcher would silently fall back to
  system ERTS at runtime instead of catching the mismatch in CI.

  Tagged `:integration` because it hits the public GitHub raw URL.
  Run with: `mix test --include integration`
  """

  use ExUnit.Case, async: false
  alias Batamanta.Target

  @manifest_url "https://raw.githubusercontent.com/Lorenzo-SF/Batamanta---ERTS-repository/main/MANIFEST.json"
  @floor_version "27.0"

  @tag :integration
  @tag :compat
  test "every Target.manifest_key is present in the upstream MANIFEST.json" do
    manifest = fetch_manifest!()
    sample_version = latest_full_version(manifest) || hd(manifest_versions(manifest))

    for target_atom <- Target.valid_targets() do
      key = Target.manifest_key(target_atom)
      entry = Map.get(manifest, "OTP-#{sample_version}") || %{}
      assert Map.has_key?(entry, key),
             "manifest_key #{inspect(key)} (for #{inspect(target_atom)}) is missing " <>
               "from the upstream MANIFEST.json under OTP-#{sample_version}. " <>
               "Either the upstream build pipeline hasn't shipped this target yet, " <>
               "or the key naming has drifted. Update `Target.manifest_key/1` or " <>
               "the upstream pipeline to align them."
    end
  end

  @tag :integration
  @tag :compat
  test "floor version (OTP-#{@floor_version}) is present in the upstream MANIFEST" do
    manifest = fetch_manifest!()
    assert Map.has_key?(manifest, "OTP-#{@floor_version}"),
           "Expected floor version OTP-#{@floor_version} to be in the upstream MANIFEST. " <>
             "If the mirror dropped support for #{@floor_version}, update the floor " <>
             "in this test (and in mix.exs if applicable)."
  end

  @tag :integration
  @tag :compat
  test "fetcher resolves a real URL for each target at the floor version" do
    alias Batamanta.ERTS.Fetcher

    for target_atom <- Target.valid_targets() do
      # build_platform_key/1 should never raise for any target in the matrix.
      platform = Fetcher.target_atom_to_platform(target_atom)
      key = Fetcher.build_platform_key(platform)
      assert is_binary(key), "#{inspect(target_atom)} produced nil key"

      url = Fetcher.find_erts_url(@floor_version, key, :explicit)
      assert is_binary(url),
             "No URL for #{target_atom} (key=#{key}) at OTP-#{@floor_version} in upstream MANIFEST"
    end
  end

  @tag :integration
  @tag :compat
  test "fetcher resolves a real URL for each target at the latest version" do
    alias Batamanta.ERTS.Fetcher

    manifest = fetch_manifest!()
    # OTP 28.4.2+ ships without musl (upstream Erlang dropped the prebuilt
    # musl tarballs), so the absolute-latest version in the manifest is not
    # the one we want to test full matrix coverage against. Prefer the most
    # recent version that has every target's manifest_key, fall back to
    # the absolute latest if no such version exists.
    latest_version = latest_full_version(manifest) || hd(manifest_versions(manifest))

    for target_atom <- Target.valid_targets() do
      platform = Fetcher.target_atom_to_platform(target_atom)
      key = Fetcher.build_platform_key(platform)
      url = Fetcher.find_erts_url(latest_version, key, :explicit)
      assert is_binary(url),
             "No URL for #{target_atom} (key=#{key}) at OTP-#{latest_version} (latest) in upstream MANIFEST"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_manifest! do
    :inets.start()
    :ssl.start()

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
        body
        |> Jason.decode!()
        |> Map.new(fn {k, v} -> {k, Map.new(v)} end)

      {:ok, {{_, status, _}, _, _}} ->
        flunk("Could not fetch upstream MANIFEST.json: HTTP #{status}")

      {:error, reason} ->
        flunk("Could not fetch upstream MANIFEST.json: #{inspect(reason)}")
    end
  end

  defp manifest_versions(manifest) do
    manifest
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "OTP-"))
    |> Enum.map(&String.replace_prefix(&1, "OTP-", ""))
    |> Enum.sort_by(&version_sort_key/1, :desc)
  end

  # Find the most recent OTP version in the manifest that has every
  # target's manifest_key present. As of OTP 28.4.2 the upstream Erlang
  # team dropped the prebuilt musl tarballs, so the absolute-latest version
  # is no longer suitable for full-matrix coverage tests. Returns nil if
  # no version in the manifest has every target, in which case callers
  # should fall back to the absolute latest.
  defp latest_full_version(manifest) do
    keys = Target.valid_targets() |> Enum.map(&Target.manifest_key/1)
    manifest_versions(manifest)
    |> Enum.find(fn v ->
      entry = Map.get(manifest, "OTP-#{v}") || %{}
      Enum.all?(keys, &Map.has_key?(entry, &1))
    end)
  end

  # Sort OTP versions in descending semver-ish order so we always pick a
  # "recent" version to test against. sort_key/1 is "1.0" → "001.000.000".
  defp version_sort_key(v) do
    v
    |> String.split(".")
    |> Enum.map(&String.pad_leading(&1, 4, "0"))
    |> Enum.join(".")
  end
end

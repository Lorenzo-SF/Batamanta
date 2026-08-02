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
    [sample_version | _] = manifest_versions(manifest)

    for target_atom <- Target.valid_targets() do
      # windows-arm64 is a special case: the Erlang/OTP project does not
      # ship Windows arm64 binaries as of 2026-08, so the upstream mirror
      # has no entry for it. The Fetcher handles that with a fallback to
      # windows-amd64 (see Fetcher.maybe_fallback_to_x86/3). Skip the
      # presence check for this target.
      if target_atom == :windows_arm64 do
        :ok
      else
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

      if target_atom == :windows_arm64 do
        # Skip: the Fetcher falls back to windows-amd64 at fetch time
        # because upstream OTP doesn't ship arm64 Windows binaries.
        :ok
      else
        url = Fetcher.find_erts_url(@floor_version, key, :explicit)
        assert is_binary(url),
               "No URL for #{target_atom} (key=#{key}) at OTP-#{@floor_version} in upstream MANIFEST"
      end
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

  # Sort OTP versions in descending semver-ish order so we always pick a
  # "recent" version to test against. sort_key/1 is "1.0" → "001.000.000".
  defp version_sort_key(v) do
    v
    |> String.split(".")
    |> Enum.map(&String.pad_leading(&1, 4, "0"))
    |> Enum.join(".")
  end
end

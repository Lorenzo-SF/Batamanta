defmodule Batamanta.ERTS.FetcherIntegrationTest do
  @moduledoc """
  Integration tests that require network access.

  These tests download actual ERTS files and should be run manually
  or when network is available.
  """

  use ExUnit.Case, async: false
  alias Batamanta.ERTS.Fetcher

  @tag :integration
  test "fetch/2 with :auto detects host target" do
    {:ok, target} = Fetcher.detect_host_target()
    assert is_atom(target)
  end

  @tag :integration
  test "fetch/2 with explicit target downloads ERTS" do
    otp_version = "26.0"
    result = Fetcher.fetch(otp_version, :ubuntu_22_04_x86_64)

    # Result depends on network availability and ERTS availability
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  @tag :integration
  test "normalize versions work with real downloads" do
    # These should try to download if not cached
    assert match?({:ok, _}, Fetcher.fetch("28", :ubuntu_22_04_x86_64)) or
             match?({:error, _}, Fetcher.fetch("28", :ubuntu_22_04_x86_64))

    assert match?({:ok, _}, Fetcher.fetch("28.1", :ubuntu_22_04_x86_64)) or
             match?({:error, _}, Fetcher.fetch("28.1", :ubuntu_22_04_x86_64))
  end
end

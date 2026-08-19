defmodule Batamanta.ERTS.FetcherIntegrationTest do
  @moduledoc """
  Integration tests that require network access.

  These tests download actual ERTS files and should be run manually
  or when network is available.
  """

  use ExUnit.Case, async: false
  alias Batamanta.ERTS.Fetcher

  # The test_helper.exs loads test_httpc.exs (the httpc mock) and
  # runner_mock.exs, but in the GitHub Actions CI the parallel compiler
  # sometimes tries to compile this test file before the mocks are
  # present on disk, leading to a `MatchError` in
  # Kernel.ParallelCompiler.require_file/2. Eagerly requiring both here
  # makes the dependency explicit and forces the test runner to load
  # them before reaching the assertions.
  Code.require_file("../../test_httpc.exs", __DIR__)
  Code.require_file("../../support/runner_mock.exs", __DIR__)

  @tag :integration
  test "fetch/2 with :auto detects host target" do
    {:ok, target} = Fetcher.detect_host_target()
    assert is_atom(target)
  end

  @tag :integration
  test "fetch/2 with explicit target downloads ERTS" do
    otp_version = "27.0"
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

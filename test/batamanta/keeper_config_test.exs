defmodule Batamanta.KeeperConfigTest do
  use ExUnit.Case, async: true

  alias Batamanta.KeeperConfig

  describe "from_config/1 with nil or empty" do
    test "returns defaults for nil config" do
      cfg = KeeperConfig.from_config(nil)
      assert cfg.enabled == false
      assert cfg.var == "BATAMANTA_BEAM_ALIVE"
      assert cfg.default_ms == 0
    end

    test "returns defaults for empty keyword list" do
      cfg = KeeperConfig.from_config([])
      assert cfg.enabled == false
      assert cfg.var == "BATAMANTA_BEAM_ALIVE"
      assert cfg.default_ms == 0
    end
  end

  describe "from_config/1 with valid config" do
    test "parses enabled: true with default var" do
      cfg = KeeperConfig.from_config(enabled: true)
      assert cfg.enabled == true
      assert cfg.var == "BATAMANTA_BEAM_ALIVE"
      assert cfg.default_ms == 0
    end

    test "parses custom var" do
      cfg = KeeperConfig.from_config(enabled: true, var: "MY_CLI_BEAM_ALIVE")
      assert cfg.enabled == true
      assert cfg.var == "MY_CLI_BEAM_ALIVE"
    end

    test "parses custom default_ms" do
      cfg = KeeperConfig.from_config(enabled: true, default_ms: 30_000)
      assert cfg.default_ms == 30_000
    end

    test "converts atom var to string" do
      cfg = KeeperConfig.from_config(enabled: true, var: :FOO)
      assert cfg.var == "FOO"
      assert is_binary(cfg.var)
    end
  end

  describe "validate!/1 rejection cases" do
    test "rejects non-boolean enabled" do
      assert_raise ArgumentError, ~r/enabled must be a boolean/, fn ->
        KeeperConfig.from_config(enabled: "yes")
      end
    end

    test "rejects empty var" do
      assert_raise ArgumentError, ~r/var must be a non-empty string/, fn ->
        KeeperConfig.from_config(enabled: true, var: "")
      end
    end

    test "rejects negative default_ms" do
      assert_raise ArgumentError, ~r/default_ms must be 0\.\./, fn ->
        KeeperConfig.from_config(enabled: true, default_ms: -1)
      end
    end

    test "rejects default_ms > 24h" do
      max = KeeperConfig.__max_default_ms__()
      assert_raise ArgumentError, ~r/default_ms must be 0\.\./, fn ->
        KeeperConfig.from_config(enabled: true, default_ms: max + 1)
      end
    end

    test "accepts default_ms at the boundary (24h)" do
      max = KeeperConfig.__max_default_ms__()
      cfg = KeeperConfig.from_config(enabled: true, default_ms: max)
      assert cfg.default_ms == max
    end
  end

  describe "enabled?/1" do
    test "returns true when enabled" do
      assert KeeperConfig.enabled?(%KeeperConfig{enabled: true})
    end

    test "returns false when disabled" do
      refute KeeperConfig.enabled?(%KeeperConfig{enabled: false})
    end
  end

  describe "to_env_vars/1" do
    test "emits only the disabled flag when feature is off" do
      cfg = KeeperConfig.from_config([])
      assert KeeperConfig.to_env_vars(cfg) == [{"BATAMANTA_BEAM_ALIVE_ENABLED", "0"}]
    end

    test "emits full env var set when enabled with defaults" do
      cfg = KeeperConfig.from_config(enabled: true)
      vars = KeeperConfig.to_env_vars(cfg)

      assert {"BATAMANTA_BEAM_ALIVE_ENABLED", "1"} in vars
      assert {"BATAMANTA_BEAM_ALIVE_VAR", "BATAMANTA_BEAM_ALIVE"} in vars
      assert {"BATAMANTA_BEAM_ALIVE_DEFAULT_MS", "0"} in vars
    end

    test "emits custom values when configured" do
      cfg = KeeperConfig.from_config(enabled: true, var: "FOO", default_ms: 5_000)
      vars = KeeperConfig.to_env_vars(cfg)

      assert {"BATAMANTA_BEAM_ALIVE_ENABLED", "1"} in vars
      assert {"BATAMANTA_BEAM_ALIVE_VAR", "FOO"} in vars
      assert {"BATAMANTA_BEAM_ALIVE_DEFAULT_MS", "5000"} in vars
    end

    test "default_ms is rendered as string of decimal" do
      cfg = KeeperConfig.from_config(enabled: true, default_ms: 30_000)
      vars = KeeperConfig.to_env_vars(cfg)

      ms_pair = Enum.find(vars, fn {k, _v} -> k == "BATAMANTA_BEAM_ALIVE_DEFAULT_MS" end)
      assert {"BATAMANTA_BEAM_ALIVE_DEFAULT_MS", "30000"} == ms_pair
    end
  end
end

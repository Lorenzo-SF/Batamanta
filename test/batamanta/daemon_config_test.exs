defmodule Batamanta.DaemonConfigTest do
  use ExUnit.Case, async: true

  alias Batamanta.DaemonConfig

  describe "from_config/1 (nil)" do
    test "returns disabled defaults" do
      cfg = DaemonConfig.from_config(nil)
      assert cfg.enabled == false
      assert cfg.var == "BATAMANTA_BEAM_ALIVE"
      assert cfg.default_ms == 0
      assert cfg.user_app == nil
      assert cfg.request_timeout_ms == 60_000
    end
  end

  describe "from_config/1 (empty list)" do
    test "behaves like nil" do
      cfg = DaemonConfig.from_config([])
      assert cfg.enabled == false
      assert cfg.var == "BATAMANTA_BEAM_ALIVE"
      assert cfg.default_ms == 0
    end
  end

  describe "from_config/1 (valid)" do
    test "normalizes all keys" do
      cfg =
        DaemonConfig.from_config(
          enabled: true,
          var: "MY_CLI_BEAM_ALIVE",
          default_ms: 5_000,
          user_app: :my_cli,
          request_timeout_ms: 30_000
        )

      assert cfg.enabled == true
      assert cfg.var == "MY_CLI_BEAM_ALIVE"
      assert cfg.default_ms == 5_000
      assert cfg.user_app == "my_cli"
      assert cfg.request_timeout_ms == 30_000
    end

    test "accepts user_app as string" do
      cfg = DaemonConfig.from_config(enabled: true, user_app: "my_cli")
      assert cfg.user_app == "my_cli"
    end
  end

  describe "from_config/1 (validation)" do
    test "rejects non-boolean enabled" do
      assert_raise ArgumentError, ~r/enabled must be a boolean/, fn ->
        DaemonConfig.from_config(enabled: "yes")
      end
    end

    test "rejects empty var" do
      assert_raise ArgumentError, ~r/var must be a non-empty string/, fn ->
        DaemonConfig.from_config(var: "")
      end
    end

    test "rejects negative default_ms" do
      assert_raise ArgumentError, ~r/default_ms must be/, fn ->
        DaemonConfig.from_config(default_ms: -1)
      end
    end

    test "rejects default_ms > 24h" do
      assert_raise ArgumentError, ~r/default_ms must be/, fn ->
        DaemonConfig.from_config(default_ms: 86_400_001)
      end
    end

    test "accepts default_ms == 0" do
      cfg = DaemonConfig.from_config(default_ms: 0)
      assert cfg.default_ms == 0
    end

    test "accepts default_ms == 24h cap" do
      cfg = DaemonConfig.from_config(default_ms: 86_400_000)
      assert cfg.default_ms == 86_400_000
    end

    test "rejects request_timeout_ms == 0" do
      assert_raise ArgumentError, ~r/request_timeout_ms must be/, fn ->
        DaemonConfig.from_config(request_timeout_ms: 0)
      end
    end
  end

  describe "enabled?/1" do
    test "true when enabled: true" do
      assert DaemonConfig.enabled?(%DaemonConfig{enabled: true})
    end

    test "false when enabled: false" do
      refute DaemonConfig.enabled?(%DaemonConfig{enabled: false})
    end
  end

  describe "with_resolved_user_app/1" do
    test "is a no-op when user_app already set" do
      cfg = %DaemonConfig{user_app: "my_cli"}
      assert DaemonConfig.with_resolved_user_app(cfg) == cfg
    end

    test "falls back to Mix.Project.config()[:app] when user_app is nil" do
      cfg = %DaemonConfig{user_app: nil}
      resolved = DaemonConfig.with_resolved_user_app(cfg)
      # During `mix test` Mix.Project is available, so user_app resolves
      # to the consuming app's `:app` key. The project under test is
      # `:batamanta` itself, so we expect that value.
      assert resolved.user_app == "batamanta"
      assert resolved.var == cfg.var
      assert resolved.enabled == cfg.enabled
    end
  end

  describe "to_env_vars/1 (disabled)" do
    test "emits only the kill switch" do
      cfg = %DaemonConfig{enabled: false}
      assert DaemonConfig.to_env_vars(cfg) == [{"BATAMANTA_BEAM_ALIVE_ENABLED", "0"}]
    end
  end

  describe "to_env_vars/1 (enabled)" do
    test "emits daemon config + CLI module default" do
      cfg =
        DaemonConfig.from_config(
          enabled: true,
          user_app: "my_cli",
          var: "FOO",
          default_ms: 1000,
          request_timeout_ms: 4500
        )

      vars = DaemonConfig.to_env_vars(cfg) |> Map.new()
      assert vars["BATAMANTA_BEAM_ALIVE_ENABLED"] == "1"
      assert vars["BATAMANTA_BEAM_ALIVE_VAR"] == "FOO"
      assert vars["BATAMANTA_BEAM_ALIVE_DEFAULT_MS"] == "1000"
      assert vars["BATAMANTA_DAEMON_USER_APP"] == "my_cli"
      assert vars["BATAMANTA_DAEMON_REQUEST_TIMEOUT_MS"] == "4500"
      assert vars["BATAMANTA_DAEMON_CLI_MODULE"] == "MyCli.CLI"
    end

    test "empty CLI module when user_app is nil" do
      cfg = %DaemonConfig{enabled: true, user_app: nil}
      vars = DaemonConfig.to_env_vars(cfg) |> Map.new()
      assert vars["BATAMANTA_DAEMON_CLI_MODULE"] == ""
    end
  end
end

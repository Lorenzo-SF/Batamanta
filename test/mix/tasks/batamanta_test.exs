defmodule Mix.Tasks.BatamantaTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Batamanta

  describe "validate_toolchain!/0" do
    test "passes when cargo is available" do
      try do
        Batamanta.validate_toolchain!()
        assert true
      rescue
        Mix.Error ->
          flunk("cargo should be available for tests")
      end
    end

    test "raises when cargo is not found" do
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        assert_raise Mix.Error, ~r/Rust \(cargo\) not found/, fn ->
          Batamanta.validate_toolchain!()
        end
      after
        if original_path,
          do: System.put_env("PATH", original_path),
          else: System.delete_env("PATH")
      end
    end
  end

  describe "parse_options/1" do
    test "parses erts-target option" do
      opts = Batamanta.parse_options(["--erts-target", "alpine_3_19_x86_64"])
      assert opts[:erts_target] == "alpine_3_19_x86_64"
    end

    test "parses otp-version option" do
      opts = Batamanta.parse_options(["--otp-version", "28.1"])
      assert opts[:otp_version] == "28.1"
    end

    test "parses force-os option" do
      opts = Batamanta.parse_options(["--force-os", "linux"])
      assert opts[:force_os] == "linux"
    end

    test "parses force-arch option" do
      opts = Batamanta.parse_options(["--force-arch", "aarch64"])
      assert opts[:force_arch] == "aarch64"
    end

    test "parses force-libc option" do
      opts = Batamanta.parse_options(["--force-libc", "musl"])
      assert opts[:force_libc] == "musl"
    end

    test "parses compression option" do
      opts = Batamanta.parse_options(["--compression", "9"])
      assert opts[:compression] == 9
    end

    test "parses multiple options" do
      opts =
        Batamanta.parse_options([
          "--erts-target",
          "alpine_3_19_x86_64",
          "--otp-version",
          "28.1",
          "--compression",
          "5"
        ])

      assert opts[:erts_target] == "alpine_3_19_x86_64"
      assert opts[:otp_version] == "28.1"
      assert opts[:compression] == 5
    end
  end

  describe "resolve_erts_target/2" do
    test "returns erts_target from opts" do
      result = Batamanta.resolve_erts_target([erts_target: :alpine_3_19_x86_64], [])
      assert result == :alpine_3_19_x86_64
    end

    test "returns erts_target from bata_config" do
      result = Batamanta.resolve_erts_target([], erts_target: :ubuntu_22_04_x86_64)
      assert result == :ubuntu_22_04_x86_64
    end

    test "returns :auto when not specified" do
      result = Batamanta.resolve_erts_target([], [])
      assert result == :auto
    end

    test "opts take precedence over bata_config" do
      result =
        Batamanta.resolve_erts_target(
          [erts_target: :alpine_3_19_x86_64],
          erts_target: :ubuntu_22_04_x86_64
        )

      assert result == :alpine_3_19_x86_64
    end
  end

  describe "build_override_config/2" do
    test "builds config from opts" do
      result =
        Batamanta.build_override_config(
          [force_os: "linux", force_arch: "x86_64", force_libc: "musl"],
          []
        )

      assert result.force_os == "linux"
      assert result.force_arch == "x86_64"
      assert result.force_libc == "musl"
    end

    test "builds config from bata_config when opts empty" do
      result =
        Batamanta.build_override_config(
          [],
          force_os: "macos",
          force_arch: "aarch64"
        )

      assert result.force_os == "macos"
      assert result.force_arch == "aarch64"
    end

    test "opts take precedence over bata_config" do
      result =
        Batamanta.build_override_config(
          [force_os: "linux"],
          force_os: "macos"
        )

      assert result.force_os == "linux"
    end
  end

  describe "resolve_otp_version/2" do
    test "returns otp_version from bata_config with :explicit mode" do
      result = Batamanta.resolve_otp_version([], otp_version: "26.0")
      assert result == {"26.0", :explicit}
    end

    test "returns otp_version from opts with :explicit mode" do
      result = Batamanta.resolve_otp_version([otp_version: "27.0"], [])
      assert result == {"27.0", :explicit}
    end

    test "opts take precedence over bata_config" do
      result =
        Batamanta.resolve_otp_version(
          [otp_version: "27.0"],
          otp_version: "26.0"
        )

      # Priority: opts > bata_config > system
      assert result == {"27.0", :explicit}
    end

    test "returns system OTP with :auto mode when not specified" do
      result = Batamanta.resolve_otp_version([], [])
      expected = :erlang.system_info(:otp_release) |> to_string()
      assert result == {expected, :auto}
    end
  end

  describe "resolve_format/3" do
    test "returns format from CLI option" do
      opts = [format: "escript"]
      result = Batamanta.resolve_format(opts, [], app: :test, escript: [main_module: Test.CLI])
      assert result == :escript
    end

    test "returns format from bata_config" do
      opts = []
      bata_config = [format: :escript]
      result = Batamanta.resolve_format(opts, bata_config, app: :test)
      assert result == :escript
    end

    test "returns :escript when project has escript config" do
      opts = []
      result = Batamanta.resolve_format(opts, [], app: :test, escript: [main_module: Test.CLI])
      assert result == :escript
    end

    test "returns :release when project has no escript config" do
      opts = []
      result = Batamanta.resolve_format(opts, [], app: :test)
      assert result == :release
    end

    test "CLI option takes precedence over config" do
      opts = [format: "escript"]
      bata_config = [format: :release]

      result =
        Batamanta.resolve_format(opts, bata_config, app: :test, escript: [main_module: Test.CLI])

      assert result == :escript
    end

    test "raises on invalid format" do
      opts = [format: "invalid"]

      assert_raise Mix.Error, ~r/Invalid format/, fn ->
        Batamanta.resolve_format(opts, [], app: :test)
      end
    end
  end

  describe "find_umbrella_apps/1" do
    test "returns empty list when apps_path does not exist" do
      config = [apps_path: "nonexistent_path", app: :test]
      result = Batamanta.find_umbrella_apps(config)
      assert result == []
    end

    test "finds apps with batamanta config in a temp umbrella" do
      tmp_dir = Path.join(System.tmp_dir!(), "bat_test_umbrella_#{System.unique_integer()}")
      apps_dir = Path.join(tmp_dir, "apps")
      app_a_dir = Path.join(apps_dir, "app_a")
      app_b_dir = Path.join(apps_dir, "app_b")

      File.mkdir_p!(app_a_dir)
      File.mkdir_p!(app_b_dir)

      File.write!(Path.join(app_a_dir, "mix.exs"), """
      defmodule AppA.MixProject do
        use Mix.Project

        def project do
          [
            app: :app_a,
            version: "0.1.0",
            batamanta: [format: :release]
          ]
        end
      end
      """)

      File.write!(Path.join(app_b_dir, "mix.exs"), """
      defmodule AppB.MixProject do
        use Mix.Project

        def project do
          [
            app: :app_b,
            version: "0.1.0"
          ]
        end
      end
      """)

      File.cd!(tmp_dir, fn ->
        config = [apps_path: "apps", app: :test_umbrella]
        result = Batamanta.find_umbrella_apps(config)
        # Only app_a has batamanta config
        assert length(result) == 1
        {name, _path} = List.first(result)
        assert name == :app_a
      end)

      File.rm_rf!(tmp_dir)
    end
  end

  describe "partition_apps_by_format/2" do
    test "partitions apps into release and escript based on config" do
      tmp_dir = Path.join(System.tmp_dir!(), "bat_test_partition_#{System.unique_integer()}")
      apps_dir = Path.join(tmp_dir, "apps")

      release_app_dir = Path.join(apps_dir, "release_app")
      escript_app_dir = Path.join(apps_dir, "escript_app")

      File.mkdir_p!(release_app_dir)
      File.mkdir_p!(escript_app_dir)

      File.write!(Path.join(release_app_dir, "mix.exs"), """
      defmodule ReleaseApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :release_app,
            version: "0.1.0",
            batamanta: [format: :release]
          ]
        end
      end
      """)

      File.write!(Path.join(escript_app_dir, "mix.exs"), """
      defmodule EscriptApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :escript_app,
            version: "0.1.0",
            batamanta: [format: :escript],
            escript: [main_module: EscriptApp.CLI]
          ]
        end
      end
      """)

      apps = [{:release_app, release_app_dir}, {:escript_app, escript_app_dir}]
      opts = []

      {release_apps, escript_apps} = Batamanta.partition_apps_by_format(apps, opts)

      assert length(release_apps) == 1
      assert length(escript_apps) == 1

      {rel_name, _} = List.first(release_apps)
      {esc_name, _} = List.first(escript_apps)

      assert rel_name == :release_app
      assert esc_name == :escript_app

      File.rm_rf!(tmp_dir)
    end
  end

  describe "read_umbrella_app_config/2" do
    test "reads batamanta config from a sub-app mix.exs" do
      tmp_dir = Path.join(System.tmp_dir!(), "bat_test_read_config_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule TestApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :test_app,
            version: "0.2.0",
            batamanta: [format: :release, binary_name: "custom_bin"]
          ]
        end
      end
      """)

      {config, bata_config} = Batamanta.read_umbrella_app_config(:test_app, tmp_dir)

      assert config[:app] == :test_app
      assert config[:version] == "0.2.0"
      assert bata_config[:format] == :release
      assert bata_config[:binary_name] == "custom_bin"

      File.rm_rf!(tmp_dir)
    end
  end

  describe "mtime_to_age_seconds/1" do
    test "returns 0 for non-tuple input" do
      assert Batamanta.mtime_to_age_seconds(nil) == 0
      assert Batamanta.mtime_to_age_seconds(1_700_000_000) == 0
    end

    test "computes age from datetime tuple" do
      past = {{2020, 1, 1}, {0, 0, 0}}

      age = Batamanta.mtime_to_age_seconds(past)

      assert is_integer(age)
      assert age > 0
    end
  end

  describe "build_umbrella_banner/6" do
    test "returns a Banner.Context struct with umbrella info" do
      apps = [{:app_a, "/tmp/app_a"}, {:app_b, "/tmp/app_b"}]
      target_info = %{os: "linux", arch: "x86_64", libc: "gnu"}

      ctx =
        Batamanta.build_umbrella_banner(
          "28.0",
          target_info,
          :ubuntu_22_04_x86_64,
          false,
          :auto,
          apps
        )

      assert is_map(ctx)
      assert ctx.mode == :text_only
      assert ctx.show_banner == false
      assert Enum.any?(ctx.messages, fn m -> String.contains?(m, "Umbrella apps") end)
      assert Enum.any?(ctx.messages, fn m -> String.contains?(m, "app_a, app_b") end)
    end
  end
end

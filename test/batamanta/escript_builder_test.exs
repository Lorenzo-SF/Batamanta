defmodule Batamanta.EscriptBuilderTest do
  use ExUnit.Case, async: true

  alias Batamanta.EscriptBuilder

  describe "valid_config?/1" do
    test "returns true when escript config has main_module" do
      config = [
        app: :test_app,
        escript: [
          main_module: Test.CLI
        ]
      ]

      assert EscriptBuilder.valid_config?(config) == true
    end

    test "returns false when escript config is missing" do
      config = [
        app: :test_app
      ]

      assert EscriptBuilder.valid_config?(config) == false
    end

    test "returns false when main_module is missing" do
      config = [
        app: :test_app,
        escript: []
      ]

      assert EscriptBuilder.valid_config?(config) == false
    end
  end

  describe "get_main_module/1" do
    test "returns the main module from config" do
      config = [
        escript: [
          main_module: Test.CLI
        ]
      ]

      assert EscriptBuilder.get_main_module(config) == Test.CLI
    end

    test "returns nil when no escript config" do
      config = []
      assert EscriptBuilder.get_main_module(config) == nil
    end
  end
end

defmodule BatamantaTest do
  use ExUnit.Case, async: true

  doctest Batamanta

  describe "main module" do
    test "module exists and is loaded" do
      assert Code.ensure_loaded?(Batamanta)
    end

    test "has version constant" do
      assert Batamanta.version() =~ ~r/\d+\.\d+\.\d+/
    end
  end
end

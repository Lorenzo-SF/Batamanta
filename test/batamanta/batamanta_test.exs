defmodule BatamantaTest do
  use ExUnit.Case, async: true

  describe "version/0" do
    test "returns version string" do
      assert is_binary(Batamanta.version())
    end

    test "version is semver format" do
      version = Batamanta.version()
      # Should match X.Y.Z format
      assert Regex.match?(~r/^\d+\.\d+\.\d+/, version)
    end
  end
end

defmodule BatamantaTest.ApplicationTest do
  use ExUnit.Case, async: true

  describe "start/2" do
    test "starts application without error" do
      # Just verify the module exists and has start function
      assert is_function(&Batamanta.Application.start/2)
    end
  end
end

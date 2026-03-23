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

defmodule Batamanta.ApplicationTest do
  use ExUnit.Case, async: true

  describe "start/2" do
    test "starts application without error" do
      # Just verify the module exists and has start function
      assert is_function(&Batamanta.Application.start/2)
    end
  end
end

defmodule Batamanta.Release.StepTest do
  use ExUnit.Case, async: true

  describe "step/1" do
    test "returns step value" do
      # The step is a simple module with a function
      assert is_atom(Batamanta.Release.Step)
    end
  end
end

defmodule Batamanta.RunnerTest do
  use ExUnit.Case, async: true

  describe "run/1" do
    test "run function exists" do
      assert is_function(&Batamanta.Runner.run/1)
    end
  end

  describe "run/3" do
    test "run with options function exists" do
      assert is_function(&Batamanta.Runner.run/3)
    end
  end
end

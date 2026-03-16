defmodule Batamanta.Release.StepTest do
  use ExUnit.Case, async: true

  alias Batamanta.Release.Step

  test "call/1 returns the release struct intact" do
    fake_release = %Mix.Release{
      name: :fake_app,
      version: "0.1.0",
      path: "/fake/path",
      version_path: "/fake/path/releases/0.1.0"
    }

    assert Step.call(fake_release) == fake_release
  end
end

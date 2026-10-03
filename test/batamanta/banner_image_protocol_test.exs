defmodule Batamanta.BannerImageProtocolTest do
  @moduledoc """
  The banner is invisible when protocol detection falls through to
  `:ascii`, and that fallthrough is silent: `show_banner: true` looks
  exactly like `show_banner: false` on the terminal, because both print
  the messages as plain text.

  That is not hypothetical. Detection used to key off `KITTY_PID`, which
  kitty only exports when remote control is enabled, and it had no entry
  for WaveTerm at all — so on those two terminals every `mix batamanta`
  quietly degraded to text mode with no warning.

  Detection is a pure function over an env map (`resolve_protocol/2`) so
  the table can be tested directly instead of by mutating the real
  environment, which is both global and racy under `async: true`.
  """
  use ExUnit.Case, async: true

  alias Batamanta.Banner

  @xterm %{"TERM" => "xterm-256color"}

  defp protocol_for(env, override \\ :auto) do
    {:ok, protocol} = Banner.resolve_protocol(env, override)
    protocol
  end

  describe "terminals that advertise TERM_PROGRAM" do
    test "WaveTerm uses the kitty graphics protocol" do
      assert protocol_for(Map.put(@xterm, "TERM_PROGRAM", "waveterm")) == :kitty
    end

    test "ghostty" do
      assert protocol_for(Map.put(@xterm, "TERM_PROGRAM", "ghostty")) == :kitty
    end

    test "WezTerm, matched case-insensitively" do
      assert protocol_for(Map.put(@xterm, "TERM_PROGRAM", "WezTerm")) == :kitty
    end

    test "Alacritty uses sixel" do
      assert protocol_for(Map.put(@xterm, "TERM_PROGRAM", "Alacritty")) == :sixel
    end

    test "vscode uses sixel" do
      assert protocol_for(Map.put(@xterm, "TERM_PROGRAM", "vscode")) == :sixel
    end

    test "iTerm2" do
      assert protocol_for(Map.put(@xterm, "TERM_PROGRAM", "iTerm.app")) in [:iterm2, :ascii]
    end
  end

  describe "terminals that only export a dedicated variable" do
    test "kitty via KITTY_WINDOW_ID, not just KITTY_PID" do
      # KITTY_PID is only set with remote control enabled, so keying off
      # it alone missed every default kitty install.
      assert protocol_for(Map.put(@xterm, "KITTY_WINDOW_ID", "1")) == :kitty
    end

    test "kitty still honours KITTY_PID when it is set" do
      assert protocol_for(Map.put(@xterm, "KITTY_PID", "1234")) == :kitty
    end

    test "kitty via TERM alone, for wrappers that scrub the env" do
      assert protocol_for(%{"TERM" => "xterm-kitty"}) == :kitty
    end

    test "ghostty via GHOSTTY_RESOURCES_DIR" do
      assert protocol_for(Map.put(@xterm, "GHOSTTY_RESOURCES_DIR", "/usr/share/ghostty")) ==
               :kitty
    end

    test "wezterm via WEZTERM_EXECUTABLE" do
      assert protocol_for(Map.put(@xterm, "WEZTERM_EXECUTABLE", "/usr/bin/wezterm")) == :kitty
    end

    test "iTerm2 via ITERM_SESSION_ID" do
      assert protocol_for(Map.put(@xterm, "ITERM_SESSION_ID", "w0t0p0")) == :iterm2
    end

    test "konsole" do
      assert protocol_for(Map.put(@xterm, "KONSOLE_VERSION", "240101")) == :kitty
    end

    test "foot via TERM" do
      assert protocol_for(%{"TERM" => "foot"}) == :sixel
    end
  end

  describe "an unrecognised terminal" do
    test "falls back to ascii rather than guessing" do
      assert protocol_for(@xterm) == :ascii
    end

    test "an empty env is ascii" do
      assert protocol_for(%{}) == :ascii
    end
  end

  describe "explicit override" do
    test "config wins over detection" do
      assert protocol_for(%{"TERM_PROGRAM" => "waveterm"}, :sixel) == :sixel
    end

    test "config accepts a string" do
      assert protocol_for(@xterm, "iterm2") == :iterm2
    end

    test "the env var is used when the config is auto" do
      env = Map.put(@xterm, "BATAMANTA_IMAGE_PROTOCOL", "iterm2")
      assert protocol_for(env, :auto) == :iterm2
    end

    test "config wins over the env var" do
      env = Map.put(@xterm, "BATAMANTA_IMAGE_PROTOCOL", "iterm2")
      assert protocol_for(env, :sixel) == :sixel
    end

    test "auto in the env var means auto" do
      env = Map.put(@xterm, "BATAMANTA_IMAGE_PROTOCOL", "auto")
      assert protocol_for(env, :auto) == :ascii
    end

    test "none is an alias for ascii" do
      assert protocol_for(%{"TERM_PROGRAM" => "waveterm"}, :none) == :ascii
    end

    test "matching is case-insensitive and trims" do
      assert protocol_for(@xterm, "  KITTY  ") == :kitty
    end
  end

  describe "a typo in the override" do
    test "is an error, not a silent downgrade to text mode" do
      # Silently falling back to :ascii here is indistinguishable from
      # "this terminal can't do images", which is exactly the bug that
      # made the banner disappear.
      assert {:error, message} = Banner.resolve_protocol(@xterm, :kity)
      assert message =~ "kity"
      assert message =~ "image_protocol"
    end

    test "names the env var when that is the source" do
      env = Map.put(@xterm, "BATAMANTA_IMAGE_PROTOCOL", "kitten")
      assert {:error, message} = Banner.resolve_protocol(env, :auto)
      assert message =~ "BATAMANTA_IMAGE_PROTOCOL"
    end
  end

  describe "detect_image_protocol/0" do
    test "reads the ambient environment" do
      assert Banner.detect_image_protocol() in [:kitty, :iterm2, :sixel, :ascii]
    end

    test "agrees with supports_images?/0" do
      assert Banner.supports_images?() == (Banner.detect_image_protocol() != :ascii)
    end
  end
end

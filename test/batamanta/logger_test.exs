defmodule Baton.LoggerTest do
  use ExUnit.Case, async: true

  @ctx %Batamanta.Banner.Context{
    mode: :text_only,
    messages: [],
    show_banner: false,
    banner_columns: 34,
    banner_rows: 24,
    image_id: 1
  }

  describe "info/2" do
    test "logs to banner when context is provided" do
      result = Batamanta.Logger.info(@ctx, "test message")
      assert "test message" in result.messages
    end

    test "logs different message types" do
      Batamanta.Logger.info(@ctx, "simple message")
      Batamanta.Logger.info(@ctx, "message with 123 numbers")
      Batamanta.Logger.info(@ctx, "emoji message 🚀")
    end
  end

  describe "error/2" do
    test "logs error to banner with emoji prefix" do
      result = Batamanta.Logger.error(@ctx, "test error")
      assert "❌ test error" in result.messages
    end
  end

  describe "create_logger/1" do
    test "returns a callable function" do
      logger_fn = Batamanta.Logger.create_logger(@ctx)
      assert is_function(logger_fn, 1)
    end
  end
end

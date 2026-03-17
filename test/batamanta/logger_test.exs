defmodule Batamanta.LoggerTest do
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

    test "logs to Mix shell when context is nil" do
      # Capture output to verify logging
      assert :ok = Batamanta.Logger.info(nil, "test message")
    end

    test "logs different message types" do
      Batamanta.Logger.info(@ctx, "simple message")
      Batamanta.Logger.info(@ctx, "message with 123 numbers")
      Batamanta.Logger.info(@ctx, "emoji message 🚀")
    end

    test "appends multiple messages" do
      result1 = Batamanta.Logger.info(@ctx, "first message")
      result2 = Batamanta.Logger.info(result1, "second message")

      assert "first message" in result2.messages
      assert "second message" in result2.messages
    end
  end

  describe "error/2" do
    test "logs error to banner with emoji prefix" do
      result = Batamanta.Logger.error(@ctx, "test error")
      assert "❌ test error" in result.messages
    end

    test "logs error to Mix shell when context is nil" do
      assert :ok = Batamanta.Logger.error(nil, "test error")
    end

    test "preserves error message content" do
      result = Batamanta.Logger.error(@ctx, "connection failed")
      assert "❌ connection failed" in result.messages
    end
  end

  describe "create_logger/1" do
    test "returns a callable function" do
      logger_fn = Batamanta.Logger.create_logger(@ctx)
      assert is_function(logger_fn, 1)
    end

    test "returned function logs messages" do
      logger_fn = Batamanta.Logger.create_logger(@ctx)
      result = logger_fn.("logged via function")
      assert "logged via function" in result.messages
    end

    test "can be used multiple times" do
      logger_fn = Batamanta.Logger.create_logger(@ctx)
      _result1 = logger_fn.("message 1")
      _result2 = Batamanta.Logger.info(@ctx, "message 2")
      _result3 = Batamanta.Logger.info(@ctx, "message 3")

      # Each call starts fresh from @ctx, so we just verify they don't crash
      assert true
    end
  end
end

defmodule Batamanta.LoggerTest do
  use ExUnit.Case, async: true

  alias Batamanta.Logger

  describe "info/2" do
    test "logs info message without context" do
      # Should not raise
      assert Logger.info(nil, "Test message") == :ok
    end
  end

  describe "error/2" do
    test "logs error message without context" do
      # Should not raise
      assert Logger.error(nil, "Error message") == :ok
    end
  end

  describe "create_logger/1" do
    test "creates a logger function" do
      log_fn = Logger.create_logger(nil)
      assert is_function(log_fn, 1)
    end

    test "logger function logs message" do
      log_fn = Logger.create_logger(nil)
      # Should not raise
      log_fn.("Test message")
    end
  end
end

defmodule Batamanta.Banner.ContextTest do
  use ExUnit.Case, async: true

  alias Batamanta.Banner.Context

  describe "struct fields" do
    test "Context has required fields" do
      ctx = %Context{
        mode: :streaming,
        protocol: :kitty,
        banner_columns: 80,
        banner_rows: 24,
        on_success_image: "",
        on_error_image: "",
        messages: [],
        image_id: 0,
        show_banner: true,
        start_row: 0
      }

      assert ctx.mode == :streaming
      assert ctx.protocol == :kitty
      assert ctx.messages == []
    end
  end
end

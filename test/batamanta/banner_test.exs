defmodule Batamanta.BannerTest do
  use ExUnit.Case, async: false

  alias Batamanta.Banner
  alias Batamanta.Banner.Context

  describe "Context struct" do
    test "can be created with all fields" do
      ctx = %Context{
        mode: :text_only,
        protocol: :ascii,
        banner_columns: 34,
        banner_rows: 24,
        on_success_image: "happy.png",
        on_error_image: "sad.png",
        messages: ["hello"],
        image_id: 1,
        show_banner: false
      }

      assert ctx.mode == :text_only
      assert ctx.protocol == :ascii
      assert ctx.messages == ["hello"]
    end
  end

  describe "detect_image_protocol/0" do
    test "returns a valid protocol atom" do
      result = Banner.detect_image_protocol()
      assert result in [:kitty, :iterm2, :sixel, :ascii]
    end
  end

  describe "supports_images?/0" do
    test "returns a boolean" do
      result = Banner.supports_images?()
      assert is_boolean(result)
    end
  end

  describe "append_line/2 text_only mode" do
    test "appends message and returns updated context" do
      ctx = %Context{
        mode: :text_only,
        protocol: :ascii,
        banner_columns: 0,
        banner_rows: 0,
        on_success_image: "",
        on_error_image: "",
        messages: [],
        image_id: 0,
        show_banner: false
      }

      Process.put(:batamanta_banner_ctx, ctx)
      new_ctx = Banner.append_line(ctx, "test message")

      assert new_ctx.messages == ["test message"]
      assert new_ctx.mode == :text_only
    end
  end

  describe "set_image/2" do
    test "returns :ok for text_only context" do
      ctx = %Context{
        mode: :text_only,
        protocol: :ascii,
        banner_columns: 0,
        banner_rows: 0,
        on_success_image: "",
        on_error_image: "",
        messages: [],
        image_id: 0,
        show_banner: false
      }

      assert Banner.set_image(ctx, :success) == :ok
      assert Banner.set_image(ctx, :error) == :ok
    end
  end
end

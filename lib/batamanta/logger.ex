defmodule Batamanta.Logger do
  @moduledoc """
  Streaming logger that can output to banner or standard Mix shell.

  When a banner context is provided, messages appear on the right side
  of the banner image. Otherwise, messages go to standard output.
  """

  alias Batamanta.Banner

  # Banner context type - either a Banner.Context struct or nil
  @type banner_ctx :: map() | nil

  @doc """
  Logs a message through the banner or standard shell.

  ## Examples

      # With banner context (streaming mode)
      ctx = Batamanta.Banner.show_with_context(["initial"])
      Batamanta.Logger.info(ctx, "Processing...")

      # Without banner (text mode)
      Batamanta.Logger.info(nil, "Processing...")
  """
  def info(nil, message) do
    Mix.shell().info(message)
  end

  def info(%Banner.Context{} = ctx, message) do
    Banner.append_line(ctx, message)
    :ok
  end

  @doc """
  Logs an error message.
  """
  def error(nil, message) do
    Mix.shell().error(message)
  end

  def error(%Banner.Context{} = ctx, message) do
    Banner.append_line(ctx, "❌ " <> message)
    :ok
  end

  @doc """
  Creates a logger function that can be passed around.

  ## Examples

      log = Batamanta.Logger.create_logger(ctx)
      log.("Message here")
  """
  def create_logger(ctx) do
    fn message -> info(ctx, message) end
  end
end

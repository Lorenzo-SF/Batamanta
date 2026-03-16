defmodule Mix.Tasks.Rust.Test do
  @moduledoc """
  Runs Rust tests for the Batamanta dispenser.

  ## Examples

      mix rust.test

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    rust_template_dir = Path.join(:code.priv_dir(:batamanta), "rust_template")

    Mix.shell().info("🦀 Running Rust tests...")

    case System.cmd("cargo", ["test"], cd: rust_template_dir, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        Mix.shell().info("✅ Rust tests passed")
        :ok

      {output, status} ->
        Mix.shell().error("❌ Rust tests failed with status: #{status}")
        Mix.shell().error(output)
        System.halt(1)
    end
  end
end

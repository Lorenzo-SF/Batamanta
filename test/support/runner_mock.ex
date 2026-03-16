defmodule Batamanta.Runner.Mock do
  @moduledoc false

  def mix_run("compile", _args), do: :ok
  def mix_run("release", _args), do: :ok

  def sys_cmd("zstd", args, _opts) do
    # When mocking zstd, we must create the dummy output file
    # the command looks like: ["-19", "--rm", "-f", in_file, "-o", out_file]
    if "-o" in args do
      out_idx = Enum.find_index(args, fn arg -> arg == "-o" end)
      out_file = Enum.at(args, out_idx + 1)
      File.write!(out_file, "dummy_zstd_payload")
    end

    {"success", 0}
  end

  def sys_cmd("strip", _args, _opts) do
    {"success", 0}
  end

  def sys_cmd("upx", _args, _opts) do
    {"success", 0}
  end

  def sys_cmd(_cmd, _args, opts) do
    dir = Keyword.get(opts, :cd)

    if dir do
      base = Path.join([dir, "target", "x86_64-unknown-linux-musl", "release"])
      File.mkdir_p!(base)
      File.write!(Path.join(base, "batamanta_dispenser"), "dummy_bin")
    end

    {"success", 0}
  end

  # Simulamos que las herramientas están instaladas
  def find_executable("cargo"), do: "/usr/bin/cargo"
  def find_executable("cross"), do: "/usr/bin/cross"
  def find_executable(_), do: "/usr/bin/mocked_path"

  def system_cmd(_cmd, _args, _opts \\ []), do: {"Mocked output", 0}
end

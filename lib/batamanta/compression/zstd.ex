defmodule Batamanta.Compression.Zstd do
  @moduledoc """
  Zstandard backend. Shells out to the system `zstd` CLI.

  Compress:  `zstd -z -f -<level> <input> -o <output>`
  Decompress: `zstd -d -f <input> -o <output>`

  Equivalent CLI options the previous inline code used:
    * `-z` is implied when `-d` is absent (compress mode).
    * `-f` overwrites the output file.
    * `--rm` is *not* used here — the packagers handle the
      intermediate tarball's lifecycle themselves; the
      compression layer only owns the final compressed file.
  """

  @behaviour Batamanta.Compression.Backend

  @impl true
  def available? do
    System.find_executable("zstd") != nil
  end

  @impl true
  def compress(input, output, level) when is_integer(level) and level >= 1 and level <= 19 do
    args = ["-z", "-f", "-#{level}", input, "-o", output]

    case System.cmd("zstd", args, stderr_to_stdout: true) do
      {_out, 0} -> {:ok, output}
      {err, code} -> {:error, "zstd failed (exit #{code}): #{err}"}
    end
  end

  @impl true
  def decompress(input, output) do
    case System.cmd("zstd", ["-d", "-f", input, "-o", output], stderr_to_stdout: true) do
      {_out, 0} -> {:ok, output}
      {err, code} -> {:error, "zstd -d failed (exit #{code}): #{err}"}
    end
  end
end

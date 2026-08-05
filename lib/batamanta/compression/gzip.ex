defmodule Batamanta.Compression.Gzip do
  @moduledoc """
  Gzip backend. Shells out to the system `gzip` CLI.

  Compress:  `gzip -<level> -c <input> > <output>`
  Decompress: `gunzip -c <input> > <output>` (via `gzip -d`)

  Gzip's level range is `1..9` (mapped from our generic
  `1..19` input by clamping). The packagers always pass
  `1..19` because the `mix batamanta --compression N` knob
  reuses the zstd range; the Gzip backend silently clamps.
  """

  @behaviour Batamanta.Compression.Backend

  @impl true
  def available? do
    System.find_executable("gzip") != nil
  end

  @impl true
  def compress(input, output, level) when is_integer(level) do
    gzip_level = level |> max(1) |> min(9)
    args = ["-#{gzip_level}", "-c", input]

    case System.cmd("gzip", args, stderr_to_stdout: true) do
      {out, 0} ->
        File.write!(output, out)
        {:ok, output}

      {err, code} ->
        {:error, "gzip failed (exit #{code}): #{err}"}
    end
  end

  @impl true
  def decompress(input, output) do
    case System.cmd("gzip", ["-d", "-c", input], stderr_to_stdout: true) do
      {out, 0} ->
        File.write!(output, out)
        {:ok, output}

      {err, code} ->
        {:error, "gzip -d failed (exit #{code}): #{err}"}
    end
  end
end

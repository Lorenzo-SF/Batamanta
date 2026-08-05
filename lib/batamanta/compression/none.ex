defmodule Batamanta.Compression.None do
  @moduledoc """
  No-op backend for the `format: :none` (or `format: :auto` with
  neither zstd nor gzip available) case. The "compressed" output
  is just a copy of the input — useful for the rare case where
  the build host has no compressor at all, or for debugging.

  No magic bytes are emitted; `Batamanta.Compression.magic_bytes/1`
  returns `<<>>` for `:none`, and `detect/1` falls through to
  `{:error, _}` for files that start with neither the zstd nor
  the gzip magic.
  """

  @behaviour Batamanta.Compression.Backend

  @impl true
  def available? do
    # The "none" backend is always available — it's a file copy.
    true
  end

  @impl true
  def compress(input, output, _level) do
    case File.cp(input, output) do
      :ok -> {:ok, output}
      {:error, reason} -> {:error, "none-compress cp failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def decompress(input, output) do
    # Decompression is identical to "compression" when there's no
    # actual compression.
    compress(input, output, 0)
  end
end

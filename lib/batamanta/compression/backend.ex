defmodule Batamanta.Compression.Backend do
  @moduledoc """
  Behaviour implemented by each compression backend
  (`Batamanta.Compression.Zstd`, `Batamanta.Compression.Gzip`,
  `Batamanta.Compression.None`).

  Backends shell out to a system CLI rather than pulling in an
  Elixir NIF dep, so the build chain stays pure and the user
  can pick whichever compressor is available on the build host.
  """

  @doc """
  Returns `true` if the backend's CLI is on `PATH` (or, for the
  `None` backend, always `true`).
  """
  @callback available?() :: boolean()

  @doc """
  Compresses `input` to `output` at the given `level`. The level
  is always an integer; the backend is responsible for clamping
  it to whatever range its CLI accepts.
  """
  @callback compress(Path.t(), Path.t(), pos_integer()) ::
              {:ok, Path.t()} | {:error, String.t()}

  @doc """
  Decompresses `input` to `output`. The output path is
  guaranteed to be freshly written.
  """
  @callback decompress(Path.t(), Path.t()) ::
              {:ok, Path.t()} | {:error, String.t()}
end

defmodule Batamanta.Compression do
  @moduledoc """
  Compression layer used by the packagers to wrap the release payload.

  The packagers (`Batamanta.Packager`, `Batamanta.EscriptPackager`) all
  need to:

    1. Compress a tarball to disk (e.g. `payload.tar.zst`).
    2. Detect what compression (if any) a given file uses, so that the
       Rust dispenser can decide how to decompress at runtime.

  This module abstracts both behind a single behaviour with three
  pluggable backends:

    * `:zstd`   — Zstandard (default; the upstream ERTS repo also
      uses zstd for the dispatcher). Magic bytes
      `<<0x28, 0xB5, 0x2F, 0xFD>>` (little-endian frame magic).
    * `:gzip`   — Gzip. Magic bytes `<<0x1F, 0x8B>>`. Useful for hosts
      that don't ship the `zstd` CLI but always have `gzip`.
    * `:none`   — No compression. The file is a raw tarball. Magic
      bytes are whatever the tar header happens to be
      (`ustar\0` for modern tar; older tars can be empty or null).

  All compress backends shell out to the system CLI rather than
  pulling in an Elixir NIF dep — keeps the build chain pure and
  lets the user pick whichever compressor is available on the
  build host.

  ## Magic bytes

  Per RFC 8478 §3.1.1, the zstd frame magic is the four bytes
  `0xFD2FB528` (big-endian), which on disk in little-endian order
  is `<<0x28, 0xB5, 0x2F, 0xFD>>`.

  ## Backend selection

  Backends are looked up by the `:format` config key. The packagers
  default to `:zstd`; pass `format: :gzip` to `mix batamanta` to
  produce a `payload.tar.gz` instead.
  """

  alias Batamanta.Compression.{Gzip, None, Zstd}

  @type backend :: :zstd | :gzip | :none
  @type format :: :zstd | :gzip | :none | :auto

  @doc """
  Returns the magic bytes (binary prefix) for the given backend.

  Useful for the Rust dispenser to identify a payload without
  trusting the file extension.
  """
  @spec magic_bytes(backend()) :: binary()
  def magic_bytes(:zstd), do: <<0x28, 0xB5, 0x2F, 0xFD>>
  def magic_bytes(:gzip), do: <<0x1F, 0x8B>>
  def magic_bytes(:none), do: <<>>

  @doc """
  Detects the backend that produced the file at `path` by reading
  its first four bytes and matching them against the known magic
  byte sequences.

  Returns `{:ok, backend}` for a recognised format, or
  `{:error, reason}` otherwise.
  """
  @spec detect(Path.t()) :: {:ok, backend()} | {:error, String.t()}
  def detect(path) do
    with {:ok, <<head::binary-size(4)>>} <- File.open(path, [:read, :binary], fn f ->
           case :file.read(f, 4) do
             {:ok, bin} -> {:ok, bin}
             e -> e
           end
         end) do
      cond do
        binary_part(head, 0, 4) == magic_bytes(:zstd) -> {:ok, :zstd}
        binary_part(head, 0, 2) == magic_bytes(:gzip) -> {:ok, :gzip}
        true -> {:error, "unrecognised compression magic: #{inspect(head)}"}
      end
    else
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Compresses `input` to `output` using the given backend and
  level. Returns `{:ok, output}` on success.
  """
  @spec compress(backend(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def compress(backend, input, output, level \\ 3) when is_integer(level) do
    module_for(backend).compress(input, output, level)
  end

  @doc """
  Decompresses `input` to `output` using the given backend.
  """
  @spec decompress(backend(), Path.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def decompress(backend, input, output) do
    module_for(backend).decompress(input, output)
  end

  @doc """
  Decompresses `input` to `output` by first detecting the backend
  from the file's magic bytes. Convenience for the Rust-dispenser
  side; not used by the packagers themselves.
  """
  @spec decompress_auto(Path.t(), Path.t()) ::
          {:ok, backend(), Path.t()} | {:error, String.t()}
  def decompress_auto(input, output) do
    with {:ok, backend} <- detect(input) do
      case decompress(backend, input, output) do
        {:ok, ^output} -> {:ok, backend, output}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Returns the canonical file extension for the backend, including
  the leading dot (e.g. `".zst"`, `".gz"`, `""`).
  """
  @spec ext(backend()) :: String.t()
  def ext(:zstd), do: ".zst"
  def ext(:gzip), do: ".gz"
  def ext(:none), do: ""

  @doc """
  Resolves a `format` config value (which may be `:auto`) to a
  concrete backend, picking the first one that is available on
  the system. `:auto` is the default and resolves to `:zstd` if
  `zstd` is on PATH, else `:gzip` if `gzip` is on PATH, else
  `:none` (with a warning).
  """
  @spec resolve_format(format()) :: {:ok, backend()} | {:error, String.t()}
  def resolve_format(backend) when backend in [:zstd, :gzip, :none] do
    cond do
      module_for(backend).available?() -> {:ok, backend}
      true -> {:error, "requested backend #{inspect(backend)} is not installed"}
    end
  end

  def resolve_format(:auto) do
    cond do
      Zstd.available?() -> {:ok, :zstd}
      Gzip.available?() -> {:ok, :gzip}
      true -> {:ok, :none}
    end
  end

  defp module_for(:zstd), do: Zstd
  defp module_for(:gzip), do: Gzip
  defp module_for(:none), do: None
end

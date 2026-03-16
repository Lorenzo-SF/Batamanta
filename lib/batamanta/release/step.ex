defmodule Batamanta.Release.Step do
  @moduledoc """
  Injectable step in the `mix release` configuration.

  It takes the assembled release and generates the monolithic executable
  along with the packaged ERTS.
  """

  @doc """
  Entry point for the Mix Releases step.
  """
  @spec call(Mix.Release.t()) :: Mix.Release.t()
  def call(%Mix.Release{} = release) do
    # For now, the base structure simply returns the struct intact.
    release
  end
end

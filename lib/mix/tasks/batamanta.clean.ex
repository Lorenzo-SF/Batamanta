defmodule Mix.Tasks.Batamanta.Clean do
  @moduledoc """
  Provides a quick way to clean the user system cache
  for dynamic downloads of the Erlang Runtime System (ERTS).
  """

  use Mix.Task

  @shortdoc "Cleans the local cache of Erlang Run-Time Systems (ERTS)"

  @doc """
  Entry point for the mix batamanta.clean task.
  """
  @impl Mix.Task
  def run(_args) do
    cache_dir = :filename.basedir(:user_cache, "batamanta")

    Mix.shell().info([:cyan, "🌌 Starting Batamanta cleanup..."])

    perform_cleanup(cache_dir)
  end

  defp perform_cleanup(cache_dir) do
    if File.exists?(cache_dir) do
      Mix.shell().info(">> Removing cache directory: #{cache_dir}")
      handle_rm_rf(File.rm_rf(cache_dir))
    else
      Mix.shell().info([:yellow, "ℹ️ Batamanta cache is already clean (does not exist)."])
    end
  end

  defp handle_rm_rf({:ok, _files_deleted}) do
    Mix.shell().info([:green, "✅ Batamanta cache successfully removed."])
  end

  defp handle_rm_rf({:error, reason, failed_file}) do
    Mix.shell().error("""
    ❌ Could not completely remove the cache.
    Failed on file: #{failed_file}
    Reason: #{inspect(reason)}
    """)
  end
end

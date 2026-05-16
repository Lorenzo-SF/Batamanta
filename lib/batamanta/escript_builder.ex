defmodule Batamanta.EscriptBuilder do
  @moduledoc false

  @doc """
  Returns true if the Mix project config contains a valid escript configuration.
 """
  def valid_config?(config) do
    escript_cfg = Keyword.get(config, :escript, [])
    Keyword.has_key?(escript_cfg, :main_module)
  end

  @doc """
  Resolves the main module from the escript configuration.
  """
  def get_main_module(config) do
    Keyword.get(config, :escript, []) |> Keyword.get(:main_module)
  end

@doc """
Computes the expected escript file path.
If a custom path is configured it is returned, otherwise "<app>.escript".
"""
  def find_escript_path(config) do
    app = Keyword.fetch!(config, :app) |> to_string()
    escript_cfg = Keyword.get(config, :escript, [])
    case Keyword.get(escript_cfg, :path) do
      nil -> app <> ".escript"
      path -> path
    end
  end

  @doc """
  Validates that the file at `file_path` is a valid escript.
  Raises Mix.Error if the file is missing, empty or does not contain
  a recognized ELF header or shebang line.
  """
  def validate_escript!(file_path) do
    unless File.exists?(file_path) do
      raise Mix.Error, "Escript file missing: #{file_path}"
    end

    content = File.read!(file_path)

      cond do
      String.length(content) == 0 ->
        raise Mix.Error, "Escript file is empty: #{file_path}"

      String.starts_with?(content, "#!") ->
        :ok

      String.slice(content, 0, 4) == <<0x7F, 0x45, 0x4C, 0x46>> ->
        :ok

      true ->
        raise Mix.Error, "Invalid escript: #{file_path}"
    end
  end

  @doc """
  Builds an escript for the given Mix project `config`.
  Returns the path to the generated escript.
  """
  def build(config, _banner_ctx) do
    app = config[:app]
    Mix.Task.run("escript.build")
    escript_path = EscriptBuilder.find_escript_path(config)
    # Update shebang to use erlexec for portable execution
    if File.exists?(escript_path) do
      content = File.read!(escript_path)
      lines = String.split(content, "\n", parts: :n)
      if Enum.at(lines, 0) =~ "#!/usr/bin/env elixir" do
        new_lines = ["#!/usr/bin/env erlexec" | List.delete_at(lines, 0)]
        File.write!(escript_path, Enum.join(new_lines, "\n"))
      end
    end
    escript_path
  end
end

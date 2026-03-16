defmodule Batamanta.RustTemplate do
  @moduledoc """
  Manages the Rust dispenser template and compilation.

  Handles copying the template, injecting the compressed payload,
  and invoking Cargo to build the final binary.

  ## Supported Targets
  - Linux: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu
  - Linux musl: x86_64-unknown-linux-musl, aarch64-unknown-linux-musl
  - macOS: x86_64-apple-darwin, aarch64-apple-darwin
  - Windows: x86_64-pc-windows-msvc (coming soon)
  """

  @doc """
  Initializes a temporary directory with the Rust dispenser template.
  """
  @spec initialize_dispenser(Path.t()) :: :ok | {:error, File.posix()}
  def initialize_dispenser(dest_dir) do
    template_dir = Path.join(:code.priv_dir(:batamanta), "rust_template")

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _} <- File.cp_r(template_dir, dest_dir) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Injects the payload into the Rust template and builds the binary.

  ## Parameters
    - `payload_path` - Path to the compressed payload tarball
    - `binary_name` - Name for the final executable
    - `target_triple` - Rust target triple (e.g., "x86_64-unknown-linux-musl")
    - `config` - Mix project configuration

  ## Returns
    - `:ok` - Success
    - `{:error, reason}` - Failure
  """
  @spec build(Path.t(), String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def build(payload_path, binary_name, target_triple, config) do
    template_dir = Path.join(:code.priv_dir(:batamanta), "rust_template")
    build_dir = Path.join(System.tmp_dir!(), "bat_build_#{:os.system_time(:millisecond)}")

    cargo_target_dir = Path.join(System.tmp_dir!(), "bat_cargo_cache")

    File.mkdir_p!(build_dir)
    File.cp_r!(template_dir, build_dir)
    File.rm_rf!(Path.join(build_dir, "target"))

    dest_payload = Path.join([build_dir, "src", "payload.tar.zst"])

    result =
      with :ok <- copy_payload(payload_path, dest_payload),
           :ok <- compile_rust(build_dir, target_triple, config, cargo_target_dir) do
        copy_binary(cargo_target_dir, binary_name, target_triple)
      end

    File.rm_rf!(build_dir)
    result
  end

  defp copy_payload(payload_path, dest_payload) do
    case File.cp(payload_path, dest_payload) do
      :ok -> :ok
      {:error, reason} -> {:error, "Error copying payload: #{inspect(reason)}"}
    end
  end

  defp compile_rust(build_dir, target_triple, config, cargo_target_dir) do
    cmd = resolve_compiler(target_triple)

    bata_config = Keyword.get(config, :batamanta, [])
    mode_str = Atom.to_string(Keyword.get(bata_config, :execution_mode, :cli))
    app_name_str = to_string(Keyword.get(config, :app, "app"))

    env = [
      {"BATAMANTA_EXEC_MODE", mode_str},
      {"BATAMANTA_APP_NAME", app_name_str},
      {"CARGO_TARGET_DIR", cargo_target_dir}
    ]

    case System.cmd(cmd, ["build", "--release", "--target", target_triple],
           cd: build_dir,
           env: env,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        {:error, "Rust compilation failed for #{target_triple}. Logs:\n#{output}"}
    end
  end

  defp resolve_compiler(_target_triple) do
    "cargo"
  end

  defp copy_binary(cargo_target_dir, binary_name, target_triple) do
    base_bin = Path.join([cargo_target_dir, target_triple, "release", "batamanta_dispenser"])

    compiled_bin =
      if String.contains?(target_triple, "windows"), do: base_bin <> ".exe", else: base_bin

    if File.exists?(binary_name), do: File.rm!(binary_name)

    with :ok <- File.cp(compiled_bin, binary_name),
         :ok <- File.chmod(binary_name, 0o755) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "Error copying compiled binary (from #{compiled_bin} to #{binary_name}): #{inspect(reason)}"}
    end
  end
end

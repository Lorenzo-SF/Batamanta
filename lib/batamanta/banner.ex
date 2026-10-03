defmodule Batamanta.Banner do
  @moduledoc """
  Banner display with terminal image support and real-time log streaming.
  """

  @image_filename_default "batamantaman_no_title.png"
  @image_filename_happy "batamantaman_happy.png"
  @image_filename_sad "batamantaman_sad.png"

  @image_cells_height 24
  @image_cells_width 34

  defmodule Context do
    @moduledoc false
    @type t :: %__MODULE__{
            mode: :streaming | :text_only,
            protocol: atom(),
            banner_columns: non_neg_integer(),
            banner_rows: non_neg_integer(),
            on_success_image: String.t(),
            on_error_image: String.t(),
            messages: [String.t()],
            image_id: non_neg_integer(),
            show_banner: boolean()
          }

    defstruct [
      :mode,
      :protocol,
      :banner_columns,
      :banner_rows,
      :on_success_image,
      :on_error_image,
      :messages,
      :image_id,
      :show_banner
    ]
  end

  def show_with_context(messages, opts \\ []) when is_list(messages) do
    show_banner = Keyword.get(opts, :show_banner, true)
    on_success_image = Keyword.get(opts, :on_success_image, @image_filename_happy)
    on_error_image = Keyword.get(opts, :on_error_image, @image_filename_sad)
    image_protocol = Keyword.get(opts, :image_protocol, :auto)

    case resolve_protocol(System.get_env(), image_protocol) do
      {:ok, protocol} ->
        render_banner(messages, show_banner, protocol, on_success_image, on_error_image)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp render_banner(messages, show_banner, protocol, on_success_image, on_error_image) do
    ctx =
      cond do
        show_banner == false ->
          text_only_ctx(messages, show_banner, on_success_image, on_error_image)

        # The banner draws with cursor movement and image escapes, which
        # is meaningless when stdout is a pipe or a file: the CI log ends
        # up full of escape sequences and a 24-row block of blanks. Text
        # mode is the honest output for a non-terminal.
        not tty?() ->
          text_only_ctx(messages, show_banner, on_success_image, on_error_image)

        # On terminals without an image protocol (Windows PowerShell,
        # cmd.exe, plain TTYs) the image can't render. Reserving the
        # 24-row banner area would just leave a big blank space with
        # the messages pushed to the right by the image width. Skip
        # straight to text mode in that case so the user actually sees
        # the banner messages, not whitespace.
        protocol == :ascii ->
          text_only_ctx(messages, show_banner, on_success_image, on_error_image)

        true ->
          display_banner_with_streaming(messages, protocol, on_success_image, on_error_image)
      end

    Process.put(:batamanta_banner_ctx, ctx)
    ctx
  end

  defp text_only_ctx(messages, show_banner, on_success_image, on_error_image) do
    print_messages(messages)

    %Context{
      mode: :text_only,
      messages: messages,
      show_banner: show_banner,
      on_success_image: on_success_image,
      on_error_image: on_error_image
    }
  end

  defp tty? do
    case IO.ANSI.enabled?() do
      nil -> false
      enabled -> enabled
    end
  end

  def append_line(%Context{mode: :text_only} = passed_ctx, message) do
    ctx = Process.get(:batamanta_banner_ctx, passed_ctx)
    clean_msg = String.replace_prefix(message, ">> ", "")
    IO.write(" >> " <> clean_msg <> "\n")

    new_ctx = %{ctx | messages: ctx.messages ++ [message]}
    Process.put(:batamanta_banner_ctx, new_ctx)
    new_ctx
  end

  def append_line(%Context{} = passed_ctx, message) do
    ctx = Process.get(:batamanta_banner_ctx, passed_ctx)
    line_index = length(ctx.messages)
    current_dist = max(ctx.banner_rows, line_index)

    move_up(ctx, current_dist)
    write_message(ctx, line_index, message)
    move_down(ctx, current_dist - line_index)

    new_ctx = %{ctx | messages: ctx.messages ++ [message]}
    Process.put(:batamanta_banner_ctx, new_ctx)
    new_ctx
  end

  defp move_up(_ctx, 0), do: :ok

  defp move_up(_ctx, dist) do
    IO.write("\e[#{dist}A\e[1G")
  end

  defp move_down(_ctx, 0), do: :ok

  defp move_down(_ctx, dist) do
    IO.write("\e[#{dist}B\e[1G")
  end

  defp write_message(ctx, 0, message) do
    clean_msg = String.replace_prefix(message, ">> ", "")
    IO.write("\e[#{ctx.banner_columns + 2}G >> " <> clean_msg)
  end

  defp write_message(ctx, line_index, message) do
    clean_msg = String.replace_prefix(message, ">> ", "")
    IO.write("\e[#{line_index}B\e[#{ctx.banner_columns + 2}G >> " <> clean_msg)
  end

  def set_image(%Context{mode: :text_only}, _status), do: :ok

  def set_image(%Context{} = passed_ctx, status) when status in [:success, :error] do
    ctx = Process.get(:batamanta_banner_ctx, passed_ctx)

    image_filename =
      case status do
        :success -> ctx.on_success_image
        :error -> ctx.on_error_image
      end

    new_image_path = find_image_path(image_filename)

    if new_image_path && File.exists?(new_image_path) do
      line_index = length(ctx.messages)
      current_dist = max(ctx.banner_rows, line_index)
      move_up(ctx, current_dist)

      _new_id = replace_image(ctx, new_image_path, status)

      move_down(ctx, current_dist)
    end

    :ok
  end

  defp replace_image(ctx, new_image_path, status) do
    if ctx.protocol == :kitty do
      IO.write("\e_Ga=d,d=i,i=#{ctx.image_id},q=2\e\\")

      target_id = if(status == :success, do: 2, else: 3)
      IO.write("\e_Ga=p,i=#{target_id},q=2,c=#{ctx.banner_columns},r=#{ctx.banner_rows}\e\\")
      Process.put(:batamanta_banner_ctx, %{ctx | image_id: target_id})
      target_id
    else
      erase_image_area(ctx.banner_rows, ctx.banner_columns)
      new_id = ctx.image_id + 1
      Process.put(:batamanta_banner_ctx, %{ctx | image_id: new_id})

      render_image_inline(
        new_image_path,
        ctx.protocol,
        ctx.banner_columns,
        ctx.banner_rows,
        new_id
      )

      new_id
    end
  end

  defp display_banner_with_streaming(messages, protocol, on_success_image, on_error_image) do
    initial_image_path = find_image_path(@image_filename_default)

    if initial_image_path && File.exists?(initial_image_path) do
      IO.write(String.duplicate("\n", @image_cells_height))

      IO.write("\e[#{@image_cells_height}A")
      IO.write("\e[1G")

      if protocol == :kitty do
        preload_kitty_images(
          initial_image_path,
          on_success_image,
          on_error_image,
          @image_cells_width,
          @image_cells_height
        )
      else
        render_image_inline(
          initial_image_path,
          protocol,
          @image_cells_width,
          @image_cells_height,
          1
        )
      end

      IO.write("\e[#{@image_cells_height}B")
      IO.write("\e[1G")

      ctx = %Context{
        mode: :streaming,
        protocol: protocol,
        banner_columns: @image_cells_width,
        banner_rows: @image_cells_height,
        on_success_image: on_success_image,
        on_error_image: on_error_image,
        messages: [],
        image_id: 1,
        show_banner: true
      }

      Enum.reduce(messages, ctx, fn msg, acc_ctx ->
        append_line(acc_ctx, msg)
      end)
    else
      Mix.shell().info("[batamanta] banner image not found, falling back to text mode")
      print_messages(messages)
      %Context{mode: :text_only, messages: messages, show_banner: true}
    end
  end

  defp erase_image_area(rows, cols) do
    IO.write("\e[s")

    for _ <- 1..rows do
      IO.write(String.duplicate(" ", cols) <> "\e[1B\e[#{cols}D")
    end

    IO.write("\e[u")
  end

  defp render_image_inline(path, protocol, cols, rows, id) do
    case protocol do
      :kitty -> render_kitty(path, cols, rows, id)
      :iterm2 -> render_iterm2(path, cols, rows)
      :sixel -> render_sixel(path, cols, rows)
      :ascii -> render_ascii(path, cols, rows)
      _ -> render_ascii(path, cols, rows)
    end
  end

  defp render_kitty(path, cols, rows, id) do
    case File.read(path) do
      {:ok, bin} ->
        b64 = Base.encode64(bin)
        chunks = chunk_string(b64, 4096)
        last_idx = length(chunks) - 1

        IO.write("\e[s")
        write_kitty_chunks(chunks, id, cols, rows, last_idx, true)
        IO.write("\e[u")

      _ ->
        nil
    end
  end

  defp write_kitty_chunks(chunks, id, cols, rows, last_idx, is_transmission) do
    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, idx} ->
      write_kitty_chunk(chunk, idx, id, cols, rows, last_idx, is_transmission)
    end)
  end

  defp write_kitty_chunk(chunk, idx, id, cols, rows, last_idx, is_transmission) do
    more = if idx < last_idx, do: 1, else: 0
    base = if is_transmission, do: "T", else: "t"

    if idx == 0 do
      opts = if is_transmission, do: "c=#{cols},r=#{rows},", else: ""
      IO.write("\e_Gf=100,a=#{base},i=#{id},q=2,#{opts}m=#{more};#{chunk}\e\\")
    else
      IO.write("\e_Gm=#{more};#{chunk}\e\\")
    end
  end

  defp preload_kitty_images(base_path, success_name, error_name, cols, rows) do
    render_kitty(base_path, cols, rows, 1)

    case find_image_path(success_name) do
      nil -> nil
      path -> transfer_kitty(path, 2)
    end

    case find_image_path(error_name) do
      nil -> nil
      path -> transfer_kitty(path, 3)
    end
  end

  defp transfer_kitty(path, id) do
    case File.read(path) do
      {:ok, bin} ->
        b64 = Base.encode64(bin)
        chunks = chunk_string(b64, 4096)
        last_idx = length(chunks) - 1
        write_kitty_chunks(chunks, id, 0, 0, last_idx, false)

      _ ->
        nil
    end
  end

  defp render_iterm2(path, cols, _rows) do
    case File.read(path) do
      {:ok, bin} ->
        b64 = Base.encode64(bin)
        IO.write("\e[s")
        IO.write("\e]1337;File=inline=1;width=#{cols}:#{b64}\a")
        IO.write("\e[u")

      _ ->
        nil
    end
  end

  defp render_sixel(path, _cols, _rows) do
    if System.find_executable("img2sixel") do
      {output, exit_code} =
        System.cmd("img2sixel", ["-w", "auto", "-h", "auto", path], stderr_to_stdout: true)

      if exit_code == 0 do
        IO.write("\e[s")
        IO.write(output)
        IO.write("\e[u")
      end
    end
  end

  defp render_ascii(path, cols, _rows) do
    if System.find_executable("img2txt") do
      {output, exit_code} =
        System.cmd("img2txt", ["-W", to_string(cols), path], stderr_to_stdout: true)

      if exit_code == 0 do
        IO.write("\e[s")
        IO.write(output)
        IO.write("\e[u")
      end
    end
  end

  defp chunk_string(string, size) do
    string
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  defp print_messages(messages) do
    Enum.each(messages, fn msg -> Mix.shell().info(msg) end)
  end

  defp find_image_path(filename) do
    base_path = System.get_env("PWD") || File.cwd!()

    app_dir_path =
      try do
        Application.app_dir(:batamanta)
      rescue
        _ -> nil
      end

    priv_candidates =
      if app_dir_path do
        [
          Path.join(app_dir_path, "priv/assets/#{filename}"),
          Path.join(app_dir_path, "../../priv/assets/#{filename}")
        ]
      else
        []
      end

    # __DIR__-relative priv path (source tree)
    source_priv = Path.expand(Path.join(__DIR__, "../../priv/assets/#{filename}"))

    candidates =
      priv_candidates ++
        [
          source_priv,
          Path.join("assets", filename),
          Path.join(base_path, "assets/#{filename}"),
          Path.join(base_path, "_build/dev/lib/batamanta/assets/#{filename}"),
          Path.join(base_path, "_build/prod/lib/batamanta/assets/#{filename}"),
          Path.join(base_path, "_build/dev/lib/batamanta/priv/assets/#{filename}"),
          Path.join(base_path, "_build/prod/lib/batamanta/priv/assets/#{filename}"),
          app_dir_path && Path.join(app_dir_path, "assets/#{filename}"),
          app_dir_path &&
            Path.join(
              app_dir_path |> Path.dirname() |> Path.dirname() |> Path.dirname(),
              "assets/#{filename}"
            ),
          Path.join(base_path, "../../assets/#{filename}"),
          Path.expand(Path.join(__DIR__, "../../assets/#{filename}"))
        ]

    candidates
    |> Enum.reject(&is_nil/1)
    |> Enum.find(fn path -> File.exists?(path) end)
  end

  @doc """
  The inline-image protocol to use for the current terminal.

  Kept as a thin wrapper over `resolve_protocol/2` for callers that just
  want the answer for the ambient environment.
  """
  @spec detect_image_protocol() :: atom()
  def detect_image_protocol do
    {:ok, protocol} = resolve_protocol(System.get_env(), :auto)
    protocol
  end

  def supports_images?, do: detect_image_protocol() != :ascii

  @doc """
  Resolves the image protocol from an explicit setting and the environment.

  `override` wins when it is anything other than `:auto`, so a project can
  pin the protocol in its `batamanta:` config when detection guesses
  wrong. When it is `:auto` the `BATAMANTA_IMAGE_PROTOCOL` environment
  variable is consulted next, which is how you A/B a guess without
  editing `mix.exs` and rebuilding.

  Returns `{:ok, protocol}` or `{:error, message}`; a typo in the
  override must not silently degrade to text-only, because that is
  indistinguishable from "this terminal has no image support".
  """
  @spec resolve_protocol(map(), atom() | String.t() | nil) ::
          {:ok, atom()} | {:error, String.t()}
  def resolve_protocol(env, override \\ :auto) do
    with {:ok, override} <- parse_protocol(override, "image_protocol"),
         {:ok, from_env} <-
           parse_protocol(env["BATAMANTA_IMAGE_PROTOCOL"], "BATAMANTA_IMAGE_PROTOCOL") do
      protocol =
        cond do
          override != :auto -> override
          from_env != :auto -> from_env
          true -> env |> detect_emulator() |> emulator_to_protocol()
        end

      {:ok, protocol}
    end
  end

  @protocol_names %{
    "auto" => :auto,
    "kitty" => :kitty,
    "iterm2" => :iterm2,
    "sixel" => :sixel,
    "ascii" => :ascii,
    "none" => :ascii
  }

  @spec parse_protocol(atom() | String.t() | nil, String.t()) ::
          {:ok, atom()} | {:error, String.t()}
  defp parse_protocol(nil, _source), do: {:ok, :auto}
  defp parse_protocol("", _source), do: {:ok, :auto}

  defp parse_protocol(value, source) do
    name = value |> to_string() |> String.trim() |> String.downcase()

    case Map.fetch(@protocol_names, name) do
      {:ok, protocol} ->
        {:ok, protocol}

      :error ->
        {:error,
         "unknown image protocol #{inspect(name)} in #{source}; " <>
           "use one of auto, kitty, iterm2, sixel, ascii"}
    end
  end

  # Terminal markers, most specific first. Each entry is
  # `{emulator, {kind, value}}`, where the kind says how to match:
  #
  #   * `:env`         — the variable is set and non-empty
  #   * `:term_program`— TERM_PROGRAM equals the value, case-insensitively
  #   * `:term`        — TERM equals the value, case-insensitively
  #
  # The old detection looked for `KITTY_PID` (which kitty only exports
  # when remote control is enabled — normally it exports
  # `KITTY_WINDOW_ID` and sets `TERM=xterm-kitty`) and had no entry at
  # all for WaveTerm, so it fell through to `:ascii` and every
  # `show_banner: true` build silently degraded to text mode.
  @emulator_probes [
    {:kitty, {:env, "KITTY_WINDOW_ID"}},
    {:kitty, {:env, "KITTY_PID"}},
    {:kitty, {:term, "xterm-kitty"}},
    {:ghostty, {:env, "GHOSTTY_RESOURCES_DIR"}},
    {:ghostty, {:term_program, "ghostty"}},
    {:wezterm, {:env, "WEZTERM_EXECUTABLE"}},
    {:wezterm, {:term_program, "wezterm"}},
    {:iterm2, {:env, "ITERM_SESSION_ID"}},
    {:iterm2, {:term_program, "iterm2"}},
    {:waveterm, {:term_program, "waveterm"}},
    {:alacritty, {:env, "ALACRITTY_LOG"}},
    {:alacritty, {:term_program, "alacritty"}},
    {:konsole, {:env, "KONSOLE_VERSION"}},
    {:foot, {:term, "foot"}},
    {:vscode, {:term_program, "vscode"}}
  ]

  @spec detect_emulator(map()) :: atom()
  defp detect_emulator(env) do
    case Enum.find(@emulator_probes, &marker_matches?(&1, env)) do
      {emulator, _marker} -> emulator
      nil -> :unknown
    end
  end

  @spec marker_matches?({atom(), {atom(), String.t()}}, map()) :: boolean()
  defp marker_matches?({_emulator, {kind, value}}, env) do
    case kind do
      :env -> present?(env[value])
      :term_program -> downcase(env["TERM_PROGRAM"]) == value
      :term -> downcase(env["TERM"]) == value
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp downcase(nil), do: ""
  defp downcase(value), do: String.downcase(value)

  # WaveTerminal speaks the kitty graphics protocol for inline images,
  # which is also what ghostty, wezterm and konsole are mapped to above.
  defp emulator_to_protocol(:kitty), do: :kitty
  defp emulator_to_protocol(:ghostty), do: :kitty
  defp emulator_to_protocol(:wezterm), do: :kitty
  defp emulator_to_protocol(:konsole), do: :kitty
  defp emulator_to_protocol(:waveterm), do: :kitty
  defp emulator_to_protocol(:iterm2), do: :iterm2
  defp emulator_to_protocol(:alacritty), do: :sixel
  defp emulator_to_protocol(:foot), do: :sixel
  defp emulator_to_protocol(:vscode), do: :sixel
  defp emulator_to_protocol(_), do: :ascii
end

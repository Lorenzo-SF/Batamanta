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
            show_banner: boolean(),
            start_row: non_neg_integer()
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
      :show_banner,
      start_row: 1
    ]
  end

  def show_with_context(messages, opts \\ []) when is_list(messages) do
    show_banner = Keyword.get(opts, :show_banner, true)
    on_success_image = Keyword.get(opts, :on_success_image, @image_filename_happy)
    on_error_image = Keyword.get(opts, :on_error_image, @image_filename_sad)

    protocol = detect_image_protocol()

    ctx =
      if show_banner == false or protocol == :ascii do
        print_messages(messages)

        %Context{
          mode: :text_only,
          messages: messages,
          show_banner: false,
          on_success_image: on_success_image,
          on_error_image: on_error_image
        }
      else
        display_banner_with_streaming(messages, protocol, on_success_image, on_error_image)
      end

    Process.put(:batamanta_banner_ctx, ctx)
    ctx
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
    message_index = length(ctx.messages)

    # Logs start after the image ends (start_row + banner_rows + 3 lines gap)
    # Each log on its own line, consecutive (no overwriting)
    target_row = ctx.start_row + ctx.banner_rows + 3 + message_index

    # Move to target row, column 1
    IO.write("\e[#{target_row}G\e[1G")

    # Write the message with newline
    IO.write(message <> "\n")

    new_ctx = %{ctx | messages: ctx.messages ++ [message]}
    Process.put(:batamanta_banner_ctx, new_ctx)
    new_ctx
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
      # Save current position
      IO.write("\e[s")

      # Move to start_row (where the banner image starts)
      IO.write("\e[#{ctx.start_row}G")

      _new_id = replace_image(ctx, new_image_path, status)

      # Restore position
      IO.write("\e[u")
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
      # Get current cursor position using ANSI query
      # This works in real terminals but may fail with Mix redirection
      start_row = detect_prompt_row()

      # Move cursor to start of line
      IO.write("\r")

      # If we're not at row 1, add newlines to reach the desired start row
      if start_row > 1 do
        IO.write(String.duplicate("\n", start_row - 1))
      end

      # Save this position for message alignment
      actual_start_row = start_row

      # Write space for banner
      IO.write(String.duplicate("\n", @image_cells_height))

      # Move back up to paint the banner
      IO.write("\e[#{@image_cells_height}A")

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
        # ID 1 is default, 2 is success, 3 is error
        image_id: 1,
        show_banner: true,
        start_row: actual_start_row
      }

      Enum.reduce(messages, ctx, fn msg, acc_ctx ->
        append_line(acc_ctx, msg)
      end)
    else
      print_messages(messages)
      %Context{mode: :text_only, messages: messages, show_banner: true}
    end
  end

  # Detects the row where the banner should start
  # Note: With Mix redirecting stdout, we cannot reliably detect cursor position.
  # We use a heuristic based on terminal width and estimate Mix output lines.
  defp detect_prompt_row do
    case :io.columns() do
      {:ok, w} when w >= 120 ->
        # Very wide terminal - likely fresh state (after clear)
        1

      _ ->
        # Normal terminal - Mix shows ~2 lines of output before us
        # (e.g., "==> project" and "Compiling...")
        # So we start at row 3 to leave room for those
        3
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
    # 1. Transfer and display base image (ID = 1)
    render_kitty(base_path, cols, rows, 1)

    # 2. Transfer success image in background (ID = 2)
    case find_image_path(success_name) do
      nil -> nil
      path -> transfer_kitty(path, 2)
    end

    # 3. Transfer error image in background (ID = 3)
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

    candidates = [
      Path.join("assets", filename),
      Path.join(base_path, "assets/#{filename}"),
      Path.join(base_path, "_build/dev/lib/batamanta/assets/#{filename}"),
      Path.join(base_path, "_build/prod/lib/batamanta/assets/#{filename}"),
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

  def detect_image_protocol do
    emulator_to_protocol(detect_emulator())
  end

  def supports_images?, do: detect_image_protocol() != :ascii

  defp detect_emulator do
    cond do
      env_set?("KITTY_PID") ->
        :kitty

      env_set?("ITERM_SESSION_ID") ->
        :iterm2

      true ->
        case System.get_env("TERM_PROGRAM") do
          "WezTerm" -> :wezterm
          "ghostty" -> :ghostty
          "Alacritty" -> :alacritty
          "vscode" -> :vscode
          _ -> detect_by_env()
        end
    end
  end

  defp detect_by_env do
    cond do
      env_set?("KONSOLE_VERSION") -> :konsole
      env_match?("TERM", "foot") -> :foot
      true -> :unknown
    end
  end

  defp emulator_to_protocol(:kitty), do: :kitty
  defp emulator_to_protocol(:ghostty), do: :kitty
  defp emulator_to_protocol(:wezterm), do: :kitty
  defp emulator_to_protocol(:iterm2), do: :iterm2
  defp emulator_to_protocol(:alacritty), do: :sixel
  defp emulator_to_protocol(:konsole), do: :kitty
  defp emulator_to_protocol(:foot), do: :sixel
  defp emulator_to_protocol(:vscode), do: :sixel
  defp emulator_to_protocol(_), do: :ascii

  defp env_set?(v), do: System.get_env(v) not in [nil, ""]
  defp env_match?(v, m), do: String.downcase(System.get_env(v) || "") == String.downcase(m)
end

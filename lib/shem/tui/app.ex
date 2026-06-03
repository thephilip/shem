defmodule Shem.TUI.App do
  @behaviour Ratatouille.App

  # Keyboard constants (termbox key codes)
  @esc 27
  @backspace 127
  @space ?\s

  @impl true
  def init(_context) do
    %{
      mode: :dashboard,
      command_buffer: "",
      paused: false
    }
  end

  @impl true
  def update(model, msg) do
    case msg do
      {:event, %{ch: ?d, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :dashboard}

      {:event, %{ch: ?i, key: 0}} when model.command_buffer == "" ->
        %{model | mode: :interactive}

      {:event, %{key: @space}} when model.command_buffer == "" ->
        %{model | paused: !model.paused}

      {:event, %{key: @esc}} when model.command_buffer == "" ->
        %{model | paused: true}

      {:event, %{ch: ?/}} when model.command_buffer == "" ->
        %{model | command_buffer: "/"}

      {:event, %{key: @backspace}} ->
        buf = model.command_buffer
        %{model | command_buffer: if(buf == "", do: "", else: String.slice(buf, 0..-2//1))}

      {:event, %{ch: ch}} when model.command_buffer != "" and ch > 0 ->
        %{model | command_buffer: model.command_buffer <> <<ch::utf8>>}

      _ ->
        model
    end
  end

  @impl true
  def render(model) do
    # Views are implemented in Task 7; placeholder keeps compilation clean
    import Ratatouille.View
    import Ratatouille.Constants, only: [color: 1]

    view do
      row do
        column(size: 12) do
          panel(title: "Shem — mode: #{model.mode}", color: color(:green)) do
            label(content: "TUI views coming in next task.")
          end
        end
      end
    end
  end
end

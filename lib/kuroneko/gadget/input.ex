defmodule Kuroneko.Gadget.Input do
  @moduledoc """
  The KVM's keyboard, mouse and touch input to the target computer, on the
  `:keyboard`, `:mouse` and `:relative_mouse` functions of
  `Kuroneko.Gadget`.

  The process keeps the keys and buttons held and sends a report on each
  change, so callers only send changes:

      Kuroneko.Gadget.Input.key("ShiftLeft", :down)
      Kuroneko.Gadget.Input.key("KeyA", :down)
      Kuroneko.Gadget.Input.key("KeyA", :up)
      Kuroneko.Gadget.Input.key("ShiftLeft", :up)

      Kuroneko.Gadget.Input.pointer(x: 0.5, y: 0.5)
      Kuroneko.Gadget.Input.pointer(buttons: [:left])
      Kuroneko.Gadget.Input.pointer(buttons: [])
      Kuroneko.Gadget.Input.pointer(wheel: -1)

      Kuroneko.Gadget.Input.type("Hello!\\n")

      Kuroneko.Gadget.Input.relative(dx: 10, dy: -3)
      Kuroneko.Gadget.Input.touch([{0, 0.2, 0.3}, {1, 0.6, 0.3}])

  Keys are `KeyboardEvent.code` values (see `Kuroneko.Gadget.HID.Keymap`)
  or HID usages; keys the keyboard has no usage for are ignored.
  `pointer/2` and `touch/2` place the pointer from 0.0 (left, top) to 1.0
  (right, bottom) across the target's screen, with the `:mouse` function in
  its mode: an absolute mouse, a pen (where the left button puts the tip
  down) or a touch screen (where it touches). `relative/2` moves the
  `:relative_mouse`, which BIOS setups and games take.

  Input wakes a target that sleeps, where it lets its USB devices wake it.
  Without a device (the function is missing, or went away while the gadget
  changed) reports are dropped, and the device is opened again a little
  later. While the target does not take reports (unplugged, asleep), only
  the newest report is kept for when it does: no key stays held.

  ## Options

    * `:name` - the name to register, `Kuroneko.Gadget.Input` by default
    * `:keyboard`, `:mouse`, `:relative_mouse` - device paths; by default
      the devices of the functions of those names. Or `{module, arg}`, for
      input that goes elsewhere, such as over Bluetooth: a process that
      `module.start_link(arg)` starts and links, which takes each report
      as `{:report, report}` and does not wake the target
    * `:pointer_mode` - the mode of the absolute pointer, by default the
      one of the gadget's `:mouse` function
    * `:gadget` - the gadget, `Kuroneko.Gadget.default_gadget/0` by default
    * `:udc_class` - where the device controllers are, `/sys/class/udc` by
      default
  """

  use GenServer

  import Bitwise

  alias Kuroneko.Gadget.HID
  alias Kuroneko.Gadget.HID.Keymap
  alias Kuroneko.Gadget.HID.Report
  alias Kuroneko.Gadget.Input.Writer

  @retry_delay 2_000
  @wake_every_ms 1_000
  # Hosts poll the keyboard each 1 ms; a key between reports would be missed.
  @type_delay_ms 8
  @kinds [:keyboard, :mouse, :relative_mouse]
  @buttons %{left: 1, right: 2, middle: 4, back: 8, forward: 16}
  @modes %{mouse: :absolute, stylus: :stylus, touch: :touch}

  @typedoc "How the absolute pointer reports: as a mouse, a pen or a touch screen."
  @type pointer_mode() :: :absolute | :stylus | :touch

  @typedoc "A `KeyboardEvent.code` value or a HID usage."
  @type key() :: Keymap.code() | 0x04..0xDD | 0xE0..0xE7

  @type button() :: :left | :right | :middle | :back | :forward

  @type pointer_change() ::
          {:x, number()}
          | {:y, number()}
          | {:buttons, [button()]}
          | {:wheel, integer()}
          | {:pan, integer()}

  @type relative_change() ::
          {:dx, integer()}
          | {:dy, integer()}
          | {:buttons, [button()]}
          | {:wheel, integer()}
          | {:pan, integer()}

  @typedoc "A touch: an id from 0 to 9 and where, from 0.0 to 1.0."
  @type contact() :: {0..9, number(), number()}

  @type device_stats() :: %{
          device: Path.t() | nil,
          sent: non_neg_integer(),
          dropped: non_neg_integer()
        }

  @type stats() :: %{
          keyboard: device_stats(),
          mouse: device_stats(),
          relative_mouse: device_stats()
        }

  @typedoc "Where the reports of a device go: its path, or a process to start."
  @type writer() :: Path.t() | {module(), term()}

  @type option() ::
          {:name, GenServer.name() | nil}
          | {:keyboard, writer()}
          | {:mouse, writer()}
          | {:relative_mouse, writer()}
          | {:pointer_mode, pointer_mode()}
          | {:gadget, Path.t()}
          | {:udc_class, Path.t()}

  @doc "Starts the process. See the module documentation for the options."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :keyboard,
        :mouse,
        :relative_mouse,
        :pointer_mode,
        :gadget,
        name: __MODULE__,
        udc_class: "/sys/class/udc"
      ])

    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Presses or releases a key."
  @spec key(GenServer.server(), key(), :down | :up) :: :ok
  def key(server \\ __MODULE__, key, action)
      when (is_binary(key) or is_integer(key)) and action in [:down, :up],
      do: GenServer.cast(server, {:key, key, action})

  @doc """
  Types text on the target as a US keyboard would, a key at a time, some 60
  characters a second, after any text typed before. Characters that
  keyboard has no key for are left out. `release_all/1` stops the typing.
  """
  @spec type(GenServer.server(), String.t()) :: :ok
  def type(server \\ __MODULE__, text) when is_binary(text) do
    strokes =
      text
      |> String.to_charlist()
      |> Enum.map(&Keymap.character/1)
      |> Enum.reject(&is_nil/1)

    GenServer.cast(server, {:type, strokes})
  end

  @doc """
  Moves the absolute pointer, presses or releases buttons, turns the wheels
  (`:wheel` up, `:pan` right). What is not given stays as it is; the wheels
  turn only once.
  """
  @spec pointer(GenServer.server(), [pointer_change()]) :: :ok
  def pointer(server \\ __MODULE__, changes) when is_list(changes) do
    check_changes!(changes, [:x, :y, :buttons, :wheel, :pan])
    GenServer.cast(server, {:pointer, changes})
  end

  @doc """
  Moves the relative mouse by `:dx` and `:dy` (right, down), presses or
  releases its buttons, turns its wheels.
  """
  @spec relative(GenServer.server(), [relative_change()]) :: :ok
  def relative(server \\ __MODULE__, changes) when is_list(changes) do
    check_changes!(changes, [:dx, :dy, :buttons, :wheel, :pan])
    GenServer.cast(server, {:relative, changes})
  end

  @doc """
  The contacts touching the screen now, up to ten: on a touch screen each,
  else the first as the pointer with the left button.
  """
  @spec touch(GenServer.server(), [contact()]) :: :ok
  def touch(server \\ __MODULE__, contacts) when is_list(contacts) do
    Enum.each(contacts, &check_contact!/1)
    GenServer.cast(server, {:touch, Enum.take(contacts, 10)})
  end

  @doc """
  Releases all keys, buttons and touches and stops any typing, for example
  when the user goes away. It does not wake the target.
  """
  @spec release_all(GenServer.server()) :: :ok
  def release_all(server \\ __MODULE__), do: GenServer.cast(server, :release_all)

  @doc "The devices in use and the reports sent and dropped for each."
  @spec stats(GenServer.server()) :: stats()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc "The mode of the absolute pointer: `:absolute`, `:stylus` or `:touch`."
  @spec pointer_mode(GenServer.server()) :: pointer_mode()
  def pointer_mode(server \\ __MODULE__), do: GenServer.call(server, :pointer_mode)

  @impl GenServer
  def init(opts) do
    # The writers are linked: one gone is opened again.
    Process.flag(:trap_exit, true)

    state = %{
      gadget: opts[:gadget],
      udc_class: opts[:udc_class],
      paths: Map.new(@kinds, &{&1, opts[&1]}),
      pointer_mode: opts[:pointer_mode],
      writers: Map.new(@kinds, &{&1, nil}),
      sent: Map.new(@kinds, &{&1, 0}),
      dropped: Map.new(@kinds, &{&1, 0}),
      retry: nil,
      woke: nil,
      typing: :queue.new(),
      typer: nil,
      mode: :absolute,
      modifiers: 0,
      keys: [],
      buttons: 0,
      x: 0,
      y: 0,
      relative_buttons: 0
    }

    {:ok, open_devices(state)}
  end

  @impl GenServer
  def handle_cast({:key, key, action}, state),
    do: {:noreply, state |> press(key, action) |> keyboard_report_if_changed(state)}

  def handle_cast({:type, strokes}, state) do
    typing = Enum.reduce(strokes, state.typing, &:queue.in/2)
    {:noreply, next_stroke(%{state | typing: typing})}
  end

  def handle_cast({:pointer, changes}, state), do: {:noreply, move_pointer(state, changes)}

  def handle_cast({:relative, changes}, state) do
    buttons = changes |> Keyword.get(:buttons) |> button_bits(state.relative_buttons)
    wheel = changes |> Keyword.get(:wheel, 0) |> clamp()
    pan = changes |> Keyword.get(:pan, 0) |> clamp()
    [{dx, dy} | rest] = steps(Keyword.get(changes, :dx, 0), Keyword.get(changes, :dy, 0))
    state = %{state | relative_buttons: buttons}

    state =
      send_report(state, :relative_mouse, Report.relative_mouse(buttons, dx, dy, wheel, pan))

    {:noreply,
     Enum.reduce(rest, state, fn {dx, dy}, state ->
       send_report(state, :relative_mouse, Report.relative_mouse(buttons, dx, dy, 0, 0))
     end)}
  end

  def handle_cast({:touch, contacts}, %{mode: :touch} = state) do
    report =
      Report.touch(for {id, x, y} <- contacts, do: {id, Report.absolute(x), Report.absolute(y)})

    {:noreply, send_report(state, :mouse, report)}
  end

  def handle_cast({:touch, [{_id, x, y} | _rest]}, state),
    do: {:noreply, move_pointer(state, x: x, y: y, buttons: [:left])}

  def handle_cast({:touch, []}, state), do: {:noreply, move_pointer(state, buttons: [])}

  def handle_cast(:release_all, state) do
    :ok = cancel(state.typer)

    state = %{
      state
      | modifiers: 0,
        keys: [],
        buttons: 0,
        relative_buttons: 0,
        typing: :queue.new(),
        typer: nil
    }

    released =
      case state.mode do
        :absolute -> Report.mouse(0, state.x, state.y, 0, 0)
        :stylus -> Report.stylus(false, false, state.x, state.y)
        :touch -> Report.touch([])
      end

    {:noreply,
     state
     |> send_report(:keyboard, Report.keyboard(0, []), wake: false)
     |> send_report(:mouse, released, wake: false)
     |> send_report(:relative_mouse, Report.relative_mouse(0, 0, 0, 0, 0), wake: false)}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    stats =
      Map.new(@kinds, fn kind ->
        device = with %{path: path} <- state.writers[kind], do: path
        {kind, %{device: device, sent: state.sent[kind], dropped: state.dropped[kind]}}
      end)

    {:reply, stats, state}
  end

  def handle_call(:pointer_mode, _from, state), do: {:reply, state.mode, state}

  @impl GenServer
  def handle_info(:retry, state), do: {:noreply, open_devices(%{state | retry: nil})}

  def handle_info({:stroke, stroke}, state), do: {:noreply, stroke(state, stroke)}

  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(@kinds, &match?(%{pid: ^pid}, state.writers[&1])) do
      nil -> {:noreply, state}
      kind -> {:noreply, state |> put_in([:writers, kind], nil) |> schedule_retry()}
    end
  end

  defp check_changes!(changes, keys) do
    Enum.each(changes, fn
      {key, value} when key in [:x, :y] and is_number(value) ->
        :ok

      {key, value} when key in [:dx, :dy, :wheel, :pan] and is_integer(value) ->
        :ok

      {:buttons, buttons} when is_list(buttons) ->
        Enum.each(buttons, &check_button!/1)

      change ->
        raise ArgumentError, "invalid change #{inspect(change)}, expected one of #{inspect(keys)}"
    end)

    unknown = Keyword.keys(changes) -- keys
    if unknown != [], do: raise(ArgumentError, "unknown changes #{inspect(unknown)}")
  end

  defp check_button!(button) when is_map_key(@buttons, button), do: :ok
  defp check_button!(button), do: raise(ArgumentError, "unknown button #{inspect(button)}")

  defp check_contact!({id, x, y}) when id in 0..9 and is_number(x) and is_number(y), do: :ok
  defp check_contact!(contact), do: raise(ArgumentError, "invalid contact #{inspect(contact)}")

  defp next_stroke(%{typer: nil} = state) do
    case :queue.out(state.typing) do
      {{:value, stroke}, typing} -> stroke(%{state | typing: typing}, {:down, stroke})
      {:empty, _typing} -> state
    end
  end

  defp next_stroke(state), do: state

  defp stroke(state, {:down, {code, shift} = character}) do
    state = if shift, do: press_and_report(state, "ShiftLeft", :down), else: state
    state = press_and_report(state, code, :down)
    %{state | typer: Process.send_after(self(), {:stroke, {:up, character}}, @type_delay_ms)}
  end

  defp stroke(state, {:up, {code, shift}}) do
    state = press_and_report(state, code, :up)
    state = if shift, do: press_and_report(state, "ShiftLeft", :up), else: state
    %{state | typer: Process.send_after(self(), {:stroke, :next}, @type_delay_ms)}
  end

  defp stroke(state, :next), do: next_stroke(%{state | typer: nil})

  defp cancel(nil), do: :ok

  defp cancel(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp press_and_report(state, key, action),
    do: state |> press(key, action) |> keyboard_report_if_changed(state)

  defp move_pointer(state, changes) do
    new = %{
      state
      | x: changes |> Keyword.get(:x) |> absolute(state.x),
        y: changes |> Keyword.get(:y) |> absolute(state.y),
        buttons: changes |> Keyword.get(:buttons) |> button_bits(state.buttons)
    }

    wheel = changes |> Keyword.get(:wheel, 0) |> clamp()
    pan = changes |> Keyword.get(:pan, 0) |> clamp()
    moved = {new.x, new.y, new.buttons} != {state.x, state.y, state.buttons}

    case mode_report(new.mode, new, state, moved, {wheel, pan}) do
      nil -> new
      report -> send_report(new, :mouse, report)
    end
  end

  defp mode_report(:absolute, new, _old, moved, {wheel, pan})
       when moved or wheel != 0 or pan != 0,
       do: Report.mouse(new.buttons, new.x, new.y, wheel, pan)

  defp mode_report(:stylus, new, _old, true, _wheels),
    do: Report.stylus(left?(new), true, new.x, new.y)

  # A touch screen has no pointer without a touch.
  defp mode_report(:touch, new, old, true, _wheels) do
    cond do
      left?(new) -> Report.touch([{0, new.x, new.y}])
      left?(old) -> Report.touch([])
      true -> nil
    end
  end

  defp mode_report(_mode, _new, _old, _moved, _wheels), do: nil

  defp left?(state), do: (state.buttons &&& 1) == 1

  # A report moves by -127 to 127: longer moves go in steps.
  defp steps(dx, dy) do
    n = max(1, ceil(max(abs(dx), abs(dy)) / 127))

    for i <- 1..n do
      {div(dx * i, n) - div(dx * (i - 1), n), div(dy * i, n) - div(dy * (i - 1), n)}
    end
  end

  defp clamp(steps), do: steps |> max(-127) |> min(127)

  defp press(state, key, action) do
    case classify(key) do
      {:modifier, bit} when action == :down -> %{state | modifiers: state.modifiers ||| bit}
      {:modifier, bit} -> %{state | modifiers: state.modifiers &&& bnot(bit)}
      {:usage, usage} when action == :down -> %{state | keys: add_key(state.keys, usage)}
      {:usage, usage} -> %{state | keys: List.delete(state.keys, usage)}
      :unknown -> state
    end
  end

  defp classify(code) when is_binary(code) do
    case {Keymap.modifier(code), Keymap.usage(code)} do
      {nil, nil} -> :unknown
      {nil, usage} -> {:usage, usage}
      {bit, _usage} -> {:modifier, bit}
    end
  end

  defp classify(usage) when usage in 0xE0..0xE7, do: {:modifier, 1 <<< (usage - 0xE0)}
  defp classify(usage) when usage in 0x04..0xDD, do: {:usage, usage}
  defp classify(_key), do: :unknown

  # The keyboard reports six keys; more held keys are left out.
  defp add_key(keys, usage) do
    if usage in keys or length(keys) >= 6, do: keys, else: keys ++ [usage]
  end

  defp keyboard_report_if_changed(new, old) do
    if {new.modifiers, new.keys} == {old.modifiers, old.keys},
      do: new,
      else: send_report(new, :keyboard, Report.keyboard(new.modifiers, new.keys))
  end

  defp absolute(nil, current), do: current
  defp absolute(position, _current), do: Report.absolute(position)

  defp button_bits(nil, current), do: current
  defp button_bits(buttons, _current), do: Enum.reduce(buttons, 0, &(@buttons[&1] ||| &2))

  defp send_report(state, kind, report, opts \\ []) do
    case state.writers[kind] do
      %{pid: writer, wake: wakes?} ->
        state = if wakes? and Keyword.get(opts, :wake, true), do: wake(state), else: state
        :ok = Writer.write(writer, report)
        update_in(state, [:sent, kind], &(&1 + 1))

      nil ->
        update_in(state, [:dropped, kind], &(&1 + 1))
    end
  end

  # The target allowed its USB devices to wake it when it went to sleep:
  # the device controller asks it to.
  defp wake(state) do
    now = System.monotonic_time(:millisecond)

    if state.woke && now - state.woke < @wake_every_ms do
      state
    else
      _woken =
        with {:ok, udc} <- File.read(Path.join(gadget(state), "UDC")),
             dir = Path.join(state.udc_class, String.trim(udc)),
             {:ok, "suspended" <> _rest} <- File.read(Path.join(dir, "state")) do
          File.write(Path.join(dir, "srp"), "1")
        end

      %{state | woke: now}
    end
  end

  defp open_devices(state) do
    state =
      Enum.reduce(@kinds, state, fn kind, state ->
        if state.writers[kind],
          do: state,
          else: put_in(state, [:writers, kind], open(state, kind))
      end)

    state = %{state | mode: state.pointer_mode || read_pointer_mode(state)}
    if Enum.all?(@kinds, &state.writers[&1]), do: state, else: schedule_retry(state)
  end

  defp open(state, kind) do
    case state.paths[kind] do
      {module, arg} ->
        case module.start_link(arg) do
          {:ok, pid} -> %{path: nil, pid: pid, wake: false}
          _error -> nil
        end

      _path ->
        with {:ok, path} <- device_path(state, kind),
             {:ok, pid} <- Writer.start_link(path) do
          %{path: path, pid: pid, wake: true}
        else
          {:error, _reason} -> nil
        end
    end
  end

  defp device_path(state, kind) do
    case state.paths[kind] do
      nil -> HID.device(name: Atom.to_string(kind), gadget: gadget(state))
      path -> {:ok, path}
    end
  end

  defp read_pointer_mode(state) do
    dir = Kuroneko.Gadget.function_dir(:mouse, gadget: gadget(state))

    with {:ok, descriptor} <- HID.read(dir),
         {:ok, mode} <- Map.fetch(@modes, HID.builtin(descriptor)) do
      mode
    else
      :error -> :absolute
    end
  end

  # Looked up each time: the gadget may come after the process.
  defp gadget(%{gadget: nil}), do: Kuroneko.Gadget.default_gadget()
  defp gadget(%{gadget: gadget}), do: gadget

  defp schedule_retry(%{retry: nil} = state),
    do: %{state | retry: Process.send_after(self(), :retry, @retry_delay)}

  defp schedule_retry(state), do: state
end

defmodule Kuroneko.Gadget.FunctionTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.FakeConfigfs
  alias Kuroneko.Gadget.Serial

  @moduletag :tmp_dir

  defmodule Midi do
    @moduledoc false
    @behaviour Kuroneko.Gadget.Function

    @impl true
    def type, do: "midi"

    @impl true
    def default_name, do: "midi"

    @impl true
    def settings(opts) do
      case Keyword.pop(opts, :ports, 1) do
        {ports, []} when ports in 1..16 -> {:ok, %{ports: ports}}
        {ports, []} -> {:error, {:invalid_ports, ports}}
        {_ports, rest} -> {:error, {:unknown_options, __MODULE__, Keyword.keys(rest)}}
      end
    end

    @impl true
    def endpoints(_settings), do: {1, 1}

    @impl true
    def setup(dir, %{ports: ports}) do
      with :ok <- File.write(Path.join(dir, "in_ports"), "#{ports}\n"),
           do: File.write(Path.join(dir, "out_ports"), "#{ports}\n")
    end

    @impl true
    def read(dir) do
      with {:ok, text} <- File.read(Path.join(dir, "in_ports")),
           {ports, _rest} <- Integer.parse(text) do
        {:ok, %{ports: ports}}
      else
        _ -> :error
      end
    end

    @impl true
    def ready(dir, _settings), do: log(dir, "ready")

    @impl true
    def teardown(dir, _settings), do: log(dir, "teardown")

    # The calls, in a file beside the gadget's functions.
    defp log(dir, call),
      do: File.write(Path.join(dir, "../../calls"), "#{call} #{Path.basename(dir)}\n", [:append])
  end

  defmodule Printer do
    @moduledoc false
    @behaviour Kuroneko.Gadget.Function

    @impl true
    def type, do: "printer"

    @impl true
    def default_name, do: "printer"

    @impl true
    def settings(opts), do: {:ok, %{pnp: Keyword.get(opts, :pnp, "MFG:Kuroneko;")}}

    @impl true
    def endpoints(_settings), do: {1, 1}

    @impl true
    def setup(dir, %{pnp: pnp}), do: File.write(Path.join(dir, "pnp_string"), pnp)
  end

  defmodule Broken do
    @moduledoc false
    @behaviour Kuroneko.Gadget.Function

    @impl true
    def type, do: "acm"

    @impl true
    def default_name, do: "broken"

    @impl true
    def settings(_opts), do: {:ok, %{}}

    @impl true
    def endpoints(_settings), do: {2, 1}

    @impl true
    def setup(_dir, _settings), do: raise("no such attribute")
  end

  defmodule Restarting do
    @moduledoc false
    @behaviour Kuroneko.Gadget.Function

    @impl true
    def type, do: "ffs"

    @impl true
    def default_name, do: "restarting"

    @impl true
    def settings(_opts), do: {:ok, %{}}

    @impl true
    def endpoints(_settings), do: {1, 1}

    @impl true
    def setup(_dir, _settings), do: :ok

    # Readied again, as a FunctionFS function whose process starts anew,
    # it takes the gadget off the bus.
    @impl true
    def ready(dir, _settings) do
      marker = Path.join(dir, "readied")

      if File.exists?(marker),
        do: File.write(Path.join(dir, "../../UDC"), ""),
        else: File.write(marker, "")
    end
  end

  setup %{tmp_dir: tmp_dir} do
    %{gadget: gadget, udc_class: udc_class} = FakeConfigfs.gadget(tmp_dir)

    options = [
      gadget: gadget,
      udc_class: udc_class,
      endpoints: %{in: 7, out: 7},
      rmdir: &rm_rf/1,
      name: nil
    ]

    pid = start_supervised!({Kuroneko.Gadget, options})
    %{gadget: gadget, options: options, pid: pid}
  end

  # configfs takes a function's attributes with it.
  defp rm_rf(dir) do
    File.rm_rf!(dir)
    :ok
  end

  defp calls(gadget) do
    case File.read(Path.join(gadget, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "set up, counted, made again with other settings and removed", %{
    gadget: gadget,
    pid: pid
  } do
    functions = [:keyboard, {Midi, ports: 2}, Serial]
    assert :ok = Kuroneko.Gadget.configure(pid, functions)

    assert Kuroneko.Gadget.functions(pid) == [:keyboard, Serial, Midi]
    assert FakeConfigfs.read(gadget, "functions/midi.midi/in_ports") == "2\n"
    assert FakeConfigfs.read(gadget, "UDC") == "udc.0"

    assert File.read_link!(Path.join(gadget, "configs/c.1/midi.midi")) ==
             Path.join(gadget, "functions/midi.midi")

    assert %{kind: Midi, name: "midi", settings: %{ports: 2}, endpoints: {1, 1}} in Kuroneko.Gadget.instances(
             pid
           )

    # The system's network, the keyboard, the MIDI function and the serial port.
    assert %{in: 6, out: 3} = Kuroneko.Gadget.endpoints_in_use(pid)
    assert calls(gadget) == ["ready midi.midi"]

    # The same again: readied again, not made again.
    assert :ok = Kuroneko.Gadget.configure(pid, functions)
    assert calls(gadget) == ["ready midi.midi", "ready midi.midi"]

    assert :ok = Kuroneko.Gadget.configure(pid, [{Midi, ports: 4}])
    assert FakeConfigfs.read(gadget, "functions/midi.midi/in_ports") == "4\n"
    assert Enum.take(calls(gadget), -2) == ["teardown midi.midi", "ready midi.midi"]
    refute File.exists?(Path.join(gadget, "functions/acm.serial"))
    refute File.exists?(Path.join(gadget, "configs/c.1/acm.serial"))

    assert :ok = Kuroneko.Gadget.configure(pid, [])
    refute File.exists?(Path.join(gadget, "functions/midi.midi"))
    assert List.last(calls(gadget)) == "teardown midi.midi"
    assert Kuroneko.Gadget.functions(pid) == []
  end

  test "tells a module's functions by what the module reads, else as they were asked for", %{
    gadget: gadget,
    options: options,
    pid: pid
  } do
    assert :ok = Kuroneko.Gadget.configure(pid, [Printer, {Midi, name: "keys"}])

    File.write!(Path.join(gadget, "functions/printer.printer/pnp_string"), "changed")
    File.write!(Path.join(gadget, "functions/midi.keys/in_ports"), "3\n")

    assert %{settings: %{ports: 3}} =
             Enum.find(Kuroneko.Gadget.instances(pid), &(&1.kind == Midi))

    assert :ok = Kuroneko.Gadget.configure(pid, [Printer, {Midi, name: "keys"}])
    assert FakeConfigfs.read(gadget, "functions/printer.printer/pnp_string") == "changed"
    assert FakeConfigfs.read(gadget, "functions/midi.keys/in_ports") == "1\n"

    # A new process takes those there for those asked for: readied, not made again.
    stop_supervised!(Kuroneko.Gadget)
    calls = calls(gadget)

    start_supervised!({Kuroneko.Gadget, [functions: [Printer, {Midi, name: "keys"}]] ++ options})

    assert calls(gadget) == calls ++ ["ready midi.keys"]
  end

  test "refuses what the modules refuse, and goes back when one fails", %{
    gadget: gadget,
    pid: pid
  } do
    assert {:error, {:invalid_ports, 20}} = Kuroneko.Gadget.configure(pid, [{Midi, ports: 20}])

    assert {:error, {:unknown_options, Serial, [:speed]}} =
             Kuroneko.Gadget.configure(pid, [{Serial, speed: 115_200}])

    assert {:error, {:unknown_function, {FakeConfigfs, []}}} =
             Kuroneko.Gadget.configure(pid, [{FakeConfigfs, []}])

    assert {:error, {:invalid_name, Midi, "a.b"}} =
             Kuroneko.Gadget.configure(pid, [{Midi, name: "a.b"}])

    assert {:error, {:duplicate_function, Midi}} = Kuroneko.Gadget.configure(pid, [Midi, Midi])

    assert {:error, {:not_enough_endpoints, %{need: %{in: 8, out: 4}}}} =
             Kuroneko.Gadget.configure(pid, [
               Serial,
               {Serial, name: "console"},
               {Serial, name: "log"}
             ])

    assert :ok = Kuroneko.Gadget.configure(pid, [:keyboard])

    assert {:error, {%{kind: Broken}, {Broken, :setup, "no such attribute"}}} =
             Kuroneko.Gadget.configure(pid, [:keyboard, Broken])

    assert Kuroneko.Gadget.functions(pid) == [:keyboard]
    refute File.exists?(Path.join(gadget, "functions/acm.broken"))
    assert FakeConfigfs.read(gadget, "UDC") == "udc.0"
  end

  test "readies a module's functions again when nothing changes, and connects again", %{
    gadget: gadget,
    pid: pid
  } do
    assert :ok = Kuroneko.Gadget.configure(pid, [Restarting])
    assert FakeConfigfs.read(gadget, "UDC") == "udc.0"
    assert File.exists?(Path.join(gadget, "functions/ffs.restarting/readied"))

    assert :ok = Kuroneko.Gadget.configure(pid, [Restarting])
    assert FakeConfigfs.read(gadget, "UDC") == "udc.0"
  end

  test "the serial port's device", %{gadget: gadget, pid: pid} do
    assert :ok = Kuroneko.Gadget.configure(pid, [Serial, {Serial, name: "console"}])
    File.write!(Path.join(gadget, "functions/acm.serial/port_num"), "0\n")
    File.write!(Path.join(gadget, "functions/acm.console/port_num"), "1\n")

    assert Serial.tty(gadget: gadget) == {:ok, "/dev/ttyGS0"}
    assert Serial.tty(gadget: gadget, name: "console") == {:ok, "/dev/ttyGS1"}
    assert Serial.tty(gadget: gadget, name: "other") == {:error, :enoent}
  end
end

defmodule Kuroneko.Gadget.InputTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.FakeConfigfs
  alias Kuroneko.Gadget.HID
  alias Kuroneko.Gadget.Input

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    [{keyboard, keyboard_reader}, {mouse, mouse_reader}, {relative, relative_reader}] =
      Enum.map(0..2, &device!(Path.join(tmp_dir, "hidg#{&1}")))

    %{gadget: gadget, udc_class: udc_class} = FakeConfigfs.gadget(tmp_dir)
    opts = [keyboard: keyboard, mouse: mouse, relative_mouse: relative, gadget: gadget]
    pid = start_supervised!({Input, opts ++ [udc_class: udc_class, name: nil]})

    %{
      hid: pid,
      keyboard: keyboard_reader,
      mouse: mouse_reader,
      relative: relative_reader,
      opts: opts,
      gadget: gadget,
      udc_class: udc_class
    }
  end

  test "keys make boot keyboard reports", %{hid: hid, keyboard: keyboard} do
    Input.key(hid, "ShiftLeft", :down)
    Input.key(hid, "KeyA", :down)
    Input.key(hid, "KeyA", :down)
    Input.key(hid, "KeyA", :up)
    Input.key(hid, 0xE1, :up)
    Input.key(hid, "NoSuchKey", :down)

    assert reports(keyboard, 8, 4) == [
             <<0x02, 0, 0, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0x04, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0, 0, 0, 0, 0, 0>>,
             <<0, 0, 0, 0, 0, 0, 0, 0>>
           ]

    assert %{keyboard: %{sent: 4, dropped: 0}} = Input.stats(hid)
  end

  test "typing presses each key, with shift where the character needs it", %{
    hid: hid,
    keyboard: keyboard
  } do
    :ok = Input.type(hid, "aB\u00e9")

    assert reports(keyboard, 8, 6) == [
             <<0, 0, 0x04, 0, 0, 0, 0, 0>>,
             <<0, 0, 0, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0x05, 0, 0, 0, 0, 0>>,
             <<0x02, 0, 0, 0, 0, 0, 0, 0>>,
             <<0, 0, 0, 0, 0, 0, 0, 0>>
           ]
  end

  test "typing goes on in the process, after what was typed before, until a release", %{
    hid: hid,
    keyboard: keyboard
  } do
    :ok = Input.type(hid, "a")
    :ok = Input.type(hid, "b")

    assert reports(keyboard, 8, 4) == [
             <<0, 0, 0x04, 0, 0, 0, 0, 0>>,
             <<0, 0, 0, 0, 0, 0, 0, 0>>,
             <<0, 0, 0x05, 0, 0, 0, 0, 0>>,
             <<0, 0, 0, 0, 0, 0, 0, 0>>
           ]

    # The release drops the x's left to type: the z comes right after.
    :ok = Input.type(hid, String.duplicate("x", 100))
    Input.release_all(hid)
    :ok = Input.type(hid, "z")
    assert length(reports_until(keyboard, 8, <<0, 0, 0x1D, 0, 0, 0, 0, 0>>)) < 20
  end

  test "bad input raises in the caller, and the process goes on", %{hid: hid} do
    assert_raise ArgumentError, fn -> Input.pointer(hid, x: "0.5") end
    assert_raise ArgumentError, fn -> Input.pointer(hid, buttons: [:thumb]) end
    assert_raise ArgumentError, fn -> Input.relative(hid, x: 0.5) end
    assert_raise ArgumentError, fn -> Input.touch(hid, [{10, 0.1, 0.1}]) end
    assert Input.pointer_mode(hid) == :absolute
  end

  test "the boot keyboard holds six keys at most", %{hid: hid, keyboard: keyboard} do
    for key <- ~w(KeyA KeyB KeyC KeyD KeyE KeyF KeyG), do: Input.key(hid, key, :down)
    assert List.last(reports(keyboard, 8, 6)) == <<0, 0, 4, 5, 6, 7, 8, 9>>
  end

  test "the pointer keeps what is not given", %{hid: hid, mouse: mouse} do
    Input.pointer(hid, x: 0.5, y: 1.0)
    Input.pointer(hid, buttons: [:left, :middle])
    Input.pointer(hid, x: 0.5)
    Input.pointer(hid, wheel: -3)
    Input.release_all(hid)

    assert reports(mouse, 7, 4) == [
             <<0, 16_384::little-16, 32_767::little-16, 0, 0>>,
             <<5, 16_384::little-16, 32_767::little-16, 0, 0>>,
             <<5, 16_384::little-16, 32_767::little-16, -3::signed, 0>>,
             <<0, 16_384::little-16, 32_767::little-16, 0, 0>>
           ]
  end

  test "the relative mouse moves in steps a report carries", %{hid: hid, relative: relative} do
    Input.relative(hid, dx: 300, dy: -10, wheel: 1)
    Input.relative(hid, buttons: [:right, :back])

    assert reports(relative, 5, 4) == [
             <<0, 100, -3::signed, 1, 0>>,
             <<0, 100, -3::signed, 0, 0>>,
             <<0, 100, -4::signed, 0, 0>>,
             <<10, 0, 0, 0, 0>>
           ]
  end

  test "a touch screen touches with the left button", %{tmp_dir: tmp_dir, opts: opts} do
    dir = Kuroneko.Gadget.function_dir(:mouse, gadget: opts[:gadget])
    File.mkdir_p!(dir)
    :ok = HID.setup(dir, HID.descriptor(:touch))
    {touch, mouse} = device!(Path.join(tmp_dir, "touch"))
    hid = start_supervised!({Input, Keyword.put(opts, :mouse, touch) ++ [name: nil]}, id: :touch)

    assert Input.pointer_mode(hid) == :touch
    # No touch, nothing to report.
    Input.pointer(hid, x: 0.5, y: 0.5)
    Input.touch(hid, [{0, 0.0, 1.0}, {1, 1.0, 0.0}])
    Input.pointer(hid, buttons: [:left])
    Input.pointer(hid, buttons: [])

    assert [two, one, none] = reports(mouse, 62, 3)
    assert <<3, 0b11, 0, 0::16, 32_767::little-16, 0b11, 1, _::binary>> = two
    assert :binary.last(two) == 2
    assert <<3, 0b11, 0, 16_384::little-16, 16_384::little-16, _::binary>> = one
    assert :binary.last(none) == 0
  end

  test "input wakes a target that sleeps, a release does not", %{
    hid: hid,
    udc_class: udc_class
  } do
    udc = Path.join(udc_class, "udc.0")
    File.write!(Path.join(udc, "state"), "suspended\n")
    Input.release_all(hid)
    :sys.get_state(hid)
    refute File.exists?(Path.join(udc, "srp"))

    Input.key(hid, "KeyA", :down)
    :sys.get_state(hid)
    assert File.read!(Path.join(udc, "srp")) == "1"
  end

  defmodule Forward do
    # Takes reports as the gadget's writers do and hands them to a test.
    def start_link({kind, test}), do: {:ok, spawn_link(fn -> loop(kind, test) end)}

    defp loop(kind, test) do
      receive do
        {:report, report} -> send(test, {kind, report})
      end

      loop(kind, test)
    end
  end

  test "reports go to processes in place of devices, which wake nothing", %{udc_class: udc_class} do
    opts = [
      keyboard: {Forward, {:keyboard, self()}},
      mouse: {Forward, {:mouse, self()}},
      relative_mouse: {Forward, {:relative_mouse, self()}},
      pointer_mode: :absolute,
      gadget: "/no/gadget",
      udc_class: udc_class,
      name: nil
    ]

    hid = start_supervised!({Input, opts}, id: :forwarded)
    Input.key(hid, "KeyA", :down)
    Input.pointer(hid, x: 1.0, y: 0.0)

    assert_receive {:keyboard, <<0, 0, 0x04, 0, 0, 0, 0, 0>>}
    assert_receive {:mouse, <<0, 32_767::little-16, 0::little-16, 0, 0>>}
    assert Input.pointer_mode(hid) == :absolute
    assert %{keyboard: %{device: nil, sent: 1}} = Input.stats(hid)
  end

  test "without devices reports are dropped", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing")

    hid =
      start_supervised!(
        {Input, keyboard: missing, mouse: missing, relative_mouse: missing, name: nil},
        id: :missing
      )

    Input.key(hid, "KeyA", :down)
    Input.pointer(hid, x: 0.1)

    assert %{keyboard: %{device: nil, sent: 0, dropped: 1}, mouse: %{dropped: 1}} =
             Input.stats(hid)
  end

  # A FIFO standing in for a /dev/hidg* device, and a port that reads it:
  # what is written comes to the test as the port's data. The reader goes
  # with the test, even one no writer opened the FIFO for.
  defp device!(path) do
    {_output, 0} = System.cmd("mkfifo", [path])

    reader =
      Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, args: [path]])

    {:os_pid, os_pid} = Port.info(reader, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true) end)
    {path, reader}
  end

  # The next count reports of size bytes, as the reader gets them.
  defp reports(reader, size, count) do
    read(reader, size, fn reports -> length(reports) >= count end)
  end

  # The reports up to the first that is last.
  defp reports_until(reader, size, last) do
    reader
    |> read(size, &(last in &1))
    |> Enum.take_while(&(&1 != last))
    |> Kernel.++([last])
  end

  defp read(reader, size, done?, bytes \\ <<>>) do
    reports = for <<report::binary-size(^size) <- bytes>>, do: report

    if done?.(reports) do
      reports
    else
      receive do
        {^reader, {:data, data}} -> read(reader, size, done?, bytes <> data)
      after
        ExUnit.configuration()[:assert_receive_timeout] ->
          flunk("reports expected, got #{inspect(reports)}")
      end
    end
  end
end

defmodule Kuroneko.Gadget.InputTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.FakeConfigfs
  alias Kuroneko.Gadget.HID
  alias Kuroneko.Gadget.Input

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    [keyboard, mouse, relative] = devices = Enum.map(0..2, &Path.join(tmp_dir, "hidg#{&1}"))
    Enum.each(devices, &File.write!(&1, ""))
    %{gadget: gadget, udc_class: udc_class} = FakeConfigfs.gadget(tmp_dir)
    opts = [keyboard: keyboard, mouse: mouse, relative_mouse: relative, gadget: gadget]
    pid = start_supervised!({Input, opts ++ [udc_class: udc_class, name: nil]})

    %{
      hid: pid,
      keyboard: keyboard,
      mouse: mouse,
      relative: relative,
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

    :ok = Input.type(hid, String.duplicate("x", 100))
    Input.release_all(hid)
    Process.sleep(50)
    assert byte_size(File.read!(keyboard)) < 8 * 20
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
    mouse = Path.join(tmp_dir, "touch")
    File.write!(mouse, "")
    hid = start_supervised!({Input, Keyword.put(opts, :mouse, mouse) ++ [name: nil]}, id: :touch)

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

  # Waits for count reports of size bytes in the file.
  defp reports(path, size, count, tries \\ 100) do
    contents = File.read!(path)

    cond do
      byte_size(contents) >= size * count ->
        for <<report::binary-size(^size) <- contents>>, do: report

      tries == 0 ->
        flunk("#{count} reports expected in #{path}, got #{inspect(contents)}")

      true ->
        Process.sleep(10)
        reports(path, size, count, tries - 1)
    end
  end
end

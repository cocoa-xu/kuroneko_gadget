defmodule Kuroneko.GadgetTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.FakeConfigfs
  alias Kuroneko.Gadget.HID

  @moduletag :tmp_dir

  # A device controller with small FIFOs, as the NanoKVM-Go's.
  @small_fifos %{microphone: 832, speaker: 682}

  setup %{tmp_dir: tmp_dir}, do: FakeConfigfs.gadget(tmp_dir)

  test "adds the functions and binds the gadget again", %{gadget: gadget, udc_class: udc_class} do
    File.write!(Path.join(gadget, "UDC"), "")

    pid =
      start_supervised!(
        {Kuroneko.Gadget,
         functions: [:storage, :keyboard, :mouse], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert Kuroneko.Gadget.functions(pid) == [:keyboard, :mouse, :storage]
    assert FakeConfigfs.read(gadget, "UDC") == "udc.0"

    assert FakeConfigfs.read(gadget, "functions/hid.keyboard/protocol") == "1"
    assert FakeConfigfs.read(gadget, "functions/hid.keyboard/report_length") == "8"
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/protocol") == "2"
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/report_length") == "7"
    assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.0/removable") == "1"

    assert File.read_link!(Path.join(gadget, "configs/c.1/hid.keyboard")) ==
             Path.join(gadget, "functions/hid.keyboard")

    assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
  end

  test "sets up the pointer in its mode and the relative mouse", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})

    assert :ok = Kuroneko.Gadget.configure(pid, [{:mouse, mode: :touch}, :relative_mouse])
    assert Kuroneko.Gadget.functions(pid) == [:mouse, :relative_mouse]
    assert FakeConfigfs.read(gadget, "functions/hid.mouse/report_length") == "62"
    assert FakeConfigfs.read(gadget, "functions/hid.relative_mouse/subclass") == "1"
    assert FakeConfigfs.read(gadget, "functions/hid.relative_mouse/report_length") == "5"

    assert {:error, {:configfs, _path, :enoent}} =
             HID.device(name: "relative_mouse", gadget: gadget)

    # The mode is read back from the report descriptor.
    File.write!(Path.join(gadget, "UDC"), "untouched")
    assert :ok = Kuroneko.Gadget.configure(pid, [:relative_mouse, {:mouse, mode: :touch}])
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"

    assert {:error, {:invalid_mode, :mouse, :tablet}} =
             Kuroneko.Gadget.configure(pid, [{:mouse, mode: :tablet}])
  end

  test "leaves the gadget alone when nothing changes", %{gadget: gadget, udc_class: udc_class} do
    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})
    assert :ok = Kuroneko.Gadget.configure(pid, [:storage])

    # A rebind would rewrite the controller's name.
    File.write!(Path.join(gadget, "UDC"), "untouched")
    assert :ok = Kuroneko.Gadget.configure(pid, [:storage])
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
  end

  test "removes the functions not asked for", %{gadget: gadget, udc_class: udc_class} do
    File.mkdir_p!(Path.join(gadget, "functions/hid.mouse"))

    :ok =
      HID.setup(
        Path.join(gadget, "functions/hid.mouse"),
        HID.descriptor(:stylus)
      )

    File.ln_s!(
      Path.join(gadget, "functions/hid.mouse"),
      Path.join(gadget, "configs/c.1/hid.mouse")
    )

    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})

    assert Kuroneko.Gadget.functions(pid) == []
    refute File.exists?(Path.join(gadget, "functions/hid.mouse"))
    assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
  end

  test "sets up the microphone and the speaker as one audio function", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid =
      start_supervised!(
        {Kuroneko.Gadget,
         functions: [:speaker, :microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert Kuroneko.Gadget.functions(pid) == [:microphone, :speaker]
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_srate") == "48000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_ssize") == "2"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_sync") == "adaptive"

    assert File.read_link!(Path.join(gadget, "configs/c.1/uac2.audio")) ==
             Path.join(gadget, "functions/uac2.audio")
  end

  test "names the audio directions where the kernel takes names", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    # A kernel with the attributes; configfs makes them with the function.
    dir = Path.join(gadget, "functions/uac2.audio")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "c_alt0_name"), "Playback Inactive\n")
    File.write!(Path.join(dir, "int_ep_present"), "1\n")

    File.write!(Path.join(dir, "function_name"), "Source/Sink\n")

    start_supervised!(
      {Kuroneko.Gadget,
       functions: [:speaker],
       names: [speaker: "Kuroneko Speaker", microphone: "Kuroneko Microphone"],
       gadget: gadget,
       udc_class: udc_class,
       name: nil}
    )

    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_alt0_name") == "Kuroneko Speaker"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/int_ep_present") == "0"
    # The kernel's name for what is not named.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/function_name") == "Source/Sink"
    refute File.exists?(Path.join(dir, "p_alt0_name"))
  end

  test "names the drive", %{gadget: gadget, udc_class: udc_class} do
    start_supervised!(
      {Kuroneko.Gadget,
       functions: [:storage],
       names: [storage: {"Kuroneko", "Virtual Media", "0100"}],
       gadget: gadget,
       udc_class: udc_class,
       name: nil}
    )

    assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.0/inquiry_string") ==
             "KuronekoVirtual Media   0100"
  end

  test "leaves the drive's name to the kernel", %{gadget: gadget, udc_class: udc_class} do
    start_supervised!(
      {Kuroneko.Gadget, functions: [:storage], gadget: gadget, udc_class: udc_class, name: nil}
    )

    refute File.exists?(Path.join(gadget, "functions/mass_storage.disk/lun.0/inquiry_string"))
  end

  test "refuses names that are not text", %{gadget: gadget} do
    assert_raise ArgumentError, fn ->
      Kuroneko.Gadget.start_link(names: [storage: "Kuroneko"], gadget: gadget, name: nil)
    end
  end

  test "a microphone alone leaves the speaker direction out", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid =
      start_supervised!(
        {Kuroneko.Gadget,
         functions: [:microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert Kuroneko.Gadget.functions(pid) == [:microphone]
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "0"
  end

  test "tells the audio directions from the function's channel masks", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    dir = Path.join(gadget, "functions/uac2.audio")
    File.mkdir_p!(dir)
    File.ln_s!(dir, Path.join(gadget, "configs/c.1/uac2.audio"))
    File.write!(Path.join(dir, "p_chmask"), "1\n")
    File.write!(Path.join(dir, "p_srate"), "48000,44100\n")
    File.write!(Path.join(dir, "p_ssize"), "2\n")
    File.write!(Path.join(dir, "p_hs_bint"), "4\n")
    File.write!(Path.join(dir, "c_chmask"), "0\n")
    # A rebind would rewrite the controller's name.
    File.write!(Path.join(gadget, "UDC"), "untouched")

    pid =
      start_supervised!(
        {Kuroneko.Gadget,
         functions: [{:microphone, channels: 1, rates: [48_000, 44_100]}],
         gadget: gadget,
         udc_class: udc_class,
         name: nil}
      )

    assert Kuroneko.Gadget.functions(pid) == [:microphone]

    assert %{microphone: %{channels: 1, rates: [48_000, 44_100], sample_bits: 16}, speaker: nil} =
             Enum.find(Kuroneko.Gadget.instances(pid), &(&1.kind == :audio))

    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
  end

  test "sets up the formats of the audio directions", %{gadget: gadget, udc_class: udc_class} do
    pid =
      start_supervised!(
        {Kuroneko.Gadget,
         max_packet: @small_fifos, gadget: gadget, udc_class: udc_class, name: nil}
      )

    assert :ok =
             Kuroneko.Gadget.configure(pid, [
               {:microphone, channels: 1, rates: [48_000, 44_100, 96_000], sample_bits: 24},
               {:speaker, rates: [192_000], sample_bits: 32}
             ])

    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_chmask") == "1"
    # The target starts with the first rate.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_srate") == "48000,44100,96000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_ssize") == "3"
    # 97 frames of 3 bytes a millisecond fit a packet.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/p_hs_bint") == "4"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_chmask") == "3"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_srate") == "192000"
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_ssize") == "4"
    # 97 frames of 8 bytes each 500 µs do not, 49 each 250 µs do.
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_hs_bint") == "2"

    assert %{
             microphone: %{channels: 1, rates: [48_000, 44_100, 96_000], sample_bits: 24},
             speaker: %{channels: 2, rates: [192_000], sample_bits: 32}
           } = Enum.find(Kuroneko.Gadget.instances(pid), &(&1.kind == :audio))
  end

  test "takes packets as large as high speed carries by default", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})

    # 97 frames of 8 bytes each 500 µs fit 1024 bytes.
    assert :ok = Kuroneko.Gadget.configure(pid, [{:speaker, rates: [192_000], sample_bits: 32}])
    assert FakeConfigfs.read(gadget, "functions/uac2.audio/c_hs_bint") == "3"
  end

  test "leaves the audio function alone in the same format", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid =
      start_supervised!(
        {Kuroneko.Gadget,
         functions: [:microphone], gadget: gadget, udc_class: udc_class, name: nil}
      )

    File.write!(Path.join(gadget, "UDC"), "untouched")
    assert :ok = Kuroneko.Gadget.configure(pid, [{:microphone, channels: 2, rates: [48_000]}])
    assert FakeConfigfs.read(gadget, "UDC") == "untouched"
  end

  test "refuses formats the USB audio function cannot have", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})
    configure = &Kuroneko.Gadget.configure(pid, [&1])

    assert {:error, {:invalid_channels, :microphone, 9}} = configure.({:microphone, channels: 9})
    assert {:error, {:invalid_rates, :speaker, []}} = configure.({:speaker, rates: []})

    assert {:error, {:invalid_rates, :speaker, _rates}} =
             configure.({:speaker, rates: Enum.map(1..11, &(&1 * 8_000))})

    assert {:error, {:invalid_rates, :speaker, [1_000]}} = configure.({:speaker, rates: [1_000]})

    assert {:error, {:invalid_sample_bits, :speaker, 20}} =
             configure.({:speaker, sample_bits: 20})

    # 8 channels of 32 bits at 384 kHz: 49 frames of 32 bytes each 125 µs.
    assert {:error, {:too_much_bandwidth, :speaker, _format}} =
             configure.({:speaker, channels: 8, rates: [384_000], sample_bits: 32})

    # 7.1 of 24 bits at 192 kHz: 25 frames of 24 bytes each 125 µs fit 682.
    assert :ok =
             Kuroneko.Gadget.validate(
               [{:speaker, channels: 8, rates: [192_000], sample_bits: 24}],
               max_packet: @small_fifos
             )

    assert :ok = configure.({:speaker, channels: 2, rates: [384_000], sample_bits: 32})

    assert {:error, {:unknown_options, :microphone, [:volume]}} =
             configure.({:microphone, volume: 3})

    assert {:error, {:duplicate_function, :microphone}} =
             Kuroneko.Gadget.configure(pid, [:microphone, {:microphone, channels: 1}])
  end

  test "goes back to the functions it had when the controller refuses", %{
    gadget: gadget,
    udc_class: udc_class
  } do
    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})

    # Binding fails: the controller name cannot be written.
    File.rm!(Path.join(gadget, "UDC"))
    File.mkdir!(Path.join(gadget, "UDC"))

    assert {:error, {:configfs, _udc, :eisdir}} = Kuroneko.Gadget.configure(pid, [:microphone])
    assert Kuroneko.Gadget.functions(pid) == []
    refute File.exists?(Path.join(gadget, "configs/c.1/uac2.audio"))
  end

  test "refuses unknown functions", %{gadget: gadget, udc_class: udc_class} do
    pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})
    assert Kuroneko.Gadget.configure(pid, [:camera]) == {:error, {:unknown_function, :camera}}

    assert_raise ArgumentError, fn ->
      Kuroneko.Gadget.start_link(functions: [:camera], gadget: gadget, name: nil)
    end
  end

  test "tells the state of the connection to the target", %{gadget: gadget, udc_class: udc_class} do
    opts = [gadget: gadget, udc_class: udc_class]
    udc = Path.join(udc_class, "udc.0")
    File.write!(Path.join(udc, "state"), "configured\n")
    File.write!(Path.join(udc, "current_speed"), "high-speed\n")

    assert Kuroneko.Gadget.connection(opts) ==
             {:ok, %{state: :configured, speed: :high_speed, controller: "udc.0"}}

    File.write!(Path.join(udc, "state"), "not attached\n")
    File.write!(Path.join(udc, "current_speed"), "UNKNOWN\n")
    assert {:ok, %{state: :not_attached, speed: :unknown}} = Kuroneko.Gadget.connection(opts)

    File.write!(Path.join(gadget, "UDC"), "\n")
    assert Kuroneko.Gadget.connection(opts) == {:error, :no_udc}
  end

  describe "the network" do
    @device "9e:9f:51:11:f7:b2"
    @host "7a:78:1f:1f:1d:dd"

    # As the NanoKVM-Go system leaves it, with the KVM functions linked after.
    setup %{gadget: gadget} do
      ncm = Path.join(gadget, "functions/ncm.usb0")
      File.write!(Path.join(ncm, "dev_addr"), @device <> "\0\n")
      File.write!(Path.join(ncm, "host_addr"), @host <> "\0\n")
      File.write!(Path.join(ncm, "ifname"), "usb0\n")
      File.write!(Path.join(ncm, "qmult"), "5\n")
      %{ncm: ncm}
    end

    defp start_usb(context, opts \\ []) do
      opts =
        Keyword.merge(
          [
            functions: [:keyboard, :storage],
            gadget: context.gadget,
            udc_class: context.udc_class,
            network: [
              default_addresses: %{device_address: @device, host_address: @host},
              persist: keeper(self())
            ],
            name: nil
          ],
          opts
        )

      start_supervised!({Kuroneko.Gadget, opts}, id: make_ref())
    end

    defp keeper(test, result \\ :ok) do
      fn kept ->
        send(test, {:kept, kept})
        result
      end
    end

    test "tells the addresses and those by default", context do
      pid = start_usb(context)

      assert Kuroneko.Gadget.network(pid) ==
               {:ok,
                %{
                  interface: "usb0",
                  device_address: @device,
                  host_address: @host,
                  default_addresses: %{device_address: @device, host_address: @host}
                }}

      File.write!(Path.join(context.ncm, "ifname"), "(unnamed net_device)\n")
      assert {:ok, %{interface: nil}} = Kuroneko.Gadget.network(pid)

      pid = start_usb(context, network: [])
      assert {:ok, %{default_addresses: nil}} = Kuroneko.Gadget.network(pid)

      assert Kuroneko.Gadget.set_network_addresses(pid, host_address: :default) ==
               {:error, :no_default_addresses}
    end

    test "gives the target computer's end another address", context do
      pid = start_usb(context)
      File.write!(Path.join(context.gadget, "UDC"), "")

      assert :ok = Kuroneko.Gadget.set_network_addresses(pid, host_address: "02:12:34:56:78:9A")

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/host_addr") ==
               "02:12:34:56:78:9a"

      # The device's interface stays: the function is the same.
      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/ifname") == "usb0\n"
      assert FakeConfigfs.read(context.gadget, "UDC") == "udc.0"

      for function <- ["ncm.usb0", "hid.keyboard", "mass_storage.disk"] do
        assert File.read_link!(Path.join(context.gadget, "configs/c.1/#{function}")) ==
                 Path.join(context.gadget, "functions/#{function}")
      end

      assert_received {:kept, %{host_address: "02:12:34:56:78:9a"} = kept}
      refute Map.has_key?(kept, :device_address)
    end

    test "gives the device's end another address with a new function", context do
      pid = start_usb(context)

      assert :ok =
               Kuroneko.Gadget.set_network_addresses(pid,
                 device_address: "06-AA-BB-CC-DD-EE",
                 host_address: :default
               )

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/dev_addr") ==
               "06:aa:bb:cc:dd:ee"

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/host_addr") == @host
      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/qmult") == "5"
      refute File.exists?(Path.join(context.gadget, "functions/ncm.usb0/ifname"))
      assert File.exists?(Path.join(context.gadget, "configs/c.1/ncm.usb0"))

      assert_received {:kept, %{device_address: "06:aa:bb:cc:dd:ee", host_address: :default}}
    end

    test "keeps the addresses that are there", context do
      pid = start_usb(context)
      File.write!(Path.join(context.gadget, "UDC"), "untouched")

      assert :ok =
               Kuroneko.Gadget.set_network_addresses(pid,
                 device_address: :default,
                 host_address: String.upcase(@host)
               )

      assert FakeConfigfs.read(context.gadget, "UDC") == "untouched"

      assert_received {:kept, %{device_address: :default, host_address: @host}}

      assert :ok = Kuroneko.Gadget.set_network_addresses(pid, host_address: @host, persist: false)
      refute_received {:kept, _kept}
    end

    test "refuses what is not a unicast address of its own", context do
      pid = start_usb(context)
      set = &Kuroneko.Gadget.validate_network_addresses(pid, &1)

      assert set.(host_address: "02:12:34:56:78") ==
               {:error, {:invalid_address, :host_address, "02:12:34:56:78"}}

      assert set.(host_address: "02:12:34:56:78:9g") ==
               {:error, {:invalid_address, :host_address, "02:12:34:56:78:9g"}}

      assert set.(device_address: "00:00:00:00:00:00") ==
               {:error, {:invalid_address, :device_address, "00:00:00:00:00:00"}}

      assert set.(device_address: "01:00:5e:00:00:fb") ==
               {:error, {:multicast_address, :device_address, "01:00:5e:00:00:fb"}}

      assert set.(device_address: nil) == {:error, {:invalid_address, :device_address, nil}}
      assert set.(host_address: @device) == {:error, :same_addresses}
      assert set.(mac: @device) == {:error, {:unknown_options, [:mac]}}
      assert set.(persist: "yes") == {:error, {:invalid_persist, "yes"}}

      assert set.([{"host_address", @device}]) ==
               {:error, {:invalid_settings, [{"host_address", @device}]}}

      assert set.(device_address: @host, host_address: @device) == :ok

      File.write!(Path.join(context.gadget, "UDC"), "untouched")

      assert {:error, :same_addresses} =
               Kuroneko.Gadget.set_network_addresses(pid, host_address: @device)

      assert FakeConfigfs.read(context.gadget, "UDC") == "untouched"
      refute_received {:kept, _kept}
    end

    test "tells when the addresses are not kept", context do
      pid = start_usb(context, network: [persist: keeper(self(), {:error, :read_only})])

      assert Kuroneko.Gadget.set_network_addresses(pid, host_address: "02:12:34:56:78:9a") ==
               {:error, {:not_kept, :read_only}}

      assert_received {:kept, %{host_address: "02:12:34:56:78:9a"}}

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/host_addr") ==
               "02:12:34:56:78:9a"

      pid = start_usb(context, network: [])
      assert :ok = Kuroneko.Gadget.set_network_addresses(pid, host_address: @host)
      refute_received {:kept, _kept}
    end

    @tag capture_log: true
    test "connects the functions again when the new function fails", context do
      pid = start_usb(context)
      File.write!(Path.join(context.gadget, "UDC"), "")
      functions = Path.join(context.gadget, "functions")
      File.chmod!(functions, 0o555)
      on_exit(fn -> File.chmod!(functions, 0o755) end)

      assert {:error, _reason} =
               Kuroneko.Gadget.set_network_addresses(pid, device_address: "02:00:00:00:00:01")

      assert FakeConfigfs.read(context.gadget, "functions/ncm.usb0/dev_addr") == @device <> "\0\n"
      assert FakeConfigfs.read(context.gadget, "UDC") == "udc.0"

      for function <- ["ncm.usb0", "hid.keyboard", "mass_storage.disk"] do
        assert File.exists?(Path.join(context.gadget, "configs/c.1/#{function}"))
      end

      refute_received {:kept, _kept}
    end
  end

  @tag capture_log: true
  test "runs on without a gadget", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing")
    pid = start_supervised!({Kuroneko.Gadget, functions: [:storage], gadget: missing, name: nil})

    assert Kuroneko.Gadget.functions(pid) == []
    assert Kuroneko.Gadget.configure(pid, [:storage]) == {:error, {:no_gadget, missing}}
  end

  describe "several of a kind" do
    test "a storage function with several LUNs keeps their media when it changes", %{
      gadget: gadget,
      udc_class: udc_class
    } do
      pid =
        start_supervised!(
          {Kuroneko.Gadget,
           functions: [{:storage, luns: 2}], gadget: gadget, udc_class: udc_class, name: nil}
        )

      for drive <- 0..1,
          do:
            assert(
              FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.#{drive}/removable") ==
                "1"
            )

      lun1 = Path.join(gadget, "functions/mass_storage.disk/lun.1")
      File.write!(Path.join(lun1, "cdrom"), "1")
      File.write!(Path.join(lun1, "file"), "/data/images/debian.iso\n")

      assert :ok = Kuroneko.Gadget.configure(pid, [{:storage, luns: 3}])

      assert [%{kind: :network, name: "usb0"}, %{kind: :storage, name: "disk", luns: 3}] =
               Kuroneko.Gadget.instances(pid)

      assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.1/cdrom") == "1"

      assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.1/file") ==
               "/data/images/debian.iso\n"

      assert FakeConfigfs.read(gadget, "functions/mass_storage.disk/lun.2/cdrom") == "0"

      assert {:error, {:invalid_luns, 17}} =
               Kuroneko.Gadget.configure(pid, [{:storage, luns: 17}])
    end

    test "functions of a kind by their names", %{gadget: gadget, udc_class: udc_class} do
      pid = start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})

      assert :ok =
               Kuroneko.Gadget.configure(pid, [
                 :storage,
                 {:storage, name: "boot"},
                 :keyboard,
                 {:keyboard, name: "keyboard2"}
               ])

      assert Kuroneko.Gadget.functions(pid) == [:keyboard, :storage]

      assert Kuroneko.Gadget.instances(pid) |> Enum.reject(&(&1.kind == :network)) == [
               %{kind: :keyboard, name: "keyboard"},
               %{kind: :keyboard, name: "keyboard2"},
               %{kind: :storage, name: "boot", luns: 1},
               %{kind: :storage, name: "disk", luns: 1}
             ]

      assert File.exists?(Path.join(gadget, "configs/c.1/mass_storage.boot"))
      assert FakeConfigfs.read(gadget, "functions/hid.keyboard2/protocol") == "1"

      assert {:error, {:duplicate_function, {:storage, "boot"}}} =
               Kuroneko.Gadget.configure(pid, [{:storage, name: "boot"}, {:storage, name: "boot"}])

      assert {:error, {:invalid_name, :keyboard, "a.b"}} =
               Kuroneko.Gadget.configure(pid, [{:keyboard, name: "a.b"}])
    end

    test "networks: left alone unless asked for, then each with its own addresses", %{
      gadget: gadget,
      udc_class: udc_class
    } do
      File.mkdir_p!(Path.join(gadget, "strings/0x409"))
      File.write!(Path.join(gadget, "strings/0x409/serialnumber"), "0123456789abcdef\n")

      pid =
        start_supervised!({Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, name: nil})

      assert :ok = Kuroneko.Gadget.configure(pid, [:keyboard])
      assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
      assert Kuroneko.Gadget.functions(pid) == [:keyboard]

      assert :ok = Kuroneko.Gadget.configure(pid, [:network, {:network, name: "usb1"}, :keyboard])
      assert Kuroneko.Gadget.functions(pid) == [:network, :keyboard]
      device = FakeConfigfs.read(gadget, "functions/ncm.usb1/dev_addr")
      host = FakeConfigfs.read(gadget, "functions/ncm.usb1/host_addr")

      # The kernel names the interface when it binds the function.
      File.write!(Path.join(gadget, "functions/ncm.usb1/ifname"), "usb1\n")

      assert %{interface: "usb1", device_address: ^device, host_address: ^host} =
               Enum.find(Kuroneko.Gadget.instances(pid), &(&1.name == "usb1"))

      assert device =~ ~r/^[0-9a-f][26ae](:[0-9a-f]{2}){5}$/
      assert host =~ ~r/^[0-9a-f][26ae](:[0-9a-f]{2}){5}$/
      assert device != host

      # The same addresses each time.
      assert :ok = Kuroneko.Gadget.configure(pid, [:network, :keyboard])
      assert :ok = Kuroneko.Gadget.configure(pid, [:network, {:network, name: "usb1"}, :keyboard])
      assert FakeConfigfs.read(gadget, "functions/ncm.usb1/dev_addr") == device

      # Without the system's network: it goes.
      assert :ok = Kuroneko.Gadget.configure(pid, [{:network, name: "usb1"}])
      refute File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
      assert Kuroneko.Gadget.functions(pid) == [:network]
    end

    test "networks always in hand: none at all is none", %{gadget: gadget, udc_class: udc_class} do
      pid =
        start_supervised!(
          {Kuroneko.Gadget,
           gadget: gadget, udc_class: udc_class, manage_networks: true, name: nil}
        )

      assert :ok = Kuroneko.Gadget.configure(pid, [:keyboard, :storage])
      refute File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
      assert Kuroneko.Gadget.functions(pid) == [:keyboard, :storage]

      assert :ok = Kuroneko.Gadget.configure(pid, [:network, :keyboard])
      assert File.exists?(Path.join(gadget, "configs/c.1/ncm.usb0"))
    end

    test "as many endpoints as the controller has", %{gadget: gadget, udc_class: udc_class} do
      have = %{in: 7, out: 7}

      pid =
        start_supervised!(
          {Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, endpoints: have, name: nil}
        )

      # The system's network takes two of them.
      five = [:keyboard, :mouse, :relative_mouse, :storage, :microphone]
      assert :ok = Kuroneko.Gadget.configure(pid, five)

      assert {:error, {:not_enough_endpoints, %{need: %{in: 8, out: 3}, have: ^have}}} =
               Kuroneko.Gadget.configure(pid, five ++ [{:storage, name: "boot"}])

      # Without the system's network, two storage functions and a second network fit.
      assert :ok =
               Kuroneko.Gadget.validate(
                 [
                   {:network, name: "usb1"},
                   :keyboard,
                   :storage,
                   {:storage, name: "boot"},
                   :microphone
                 ],
                 endpoints: have
               )

      assert Kuroneko.Gadget.endpoints([:network, :storage, :speaker]) == {:ok, %{in: 3, out: 3}}

      # The system's network and the five, the microphone without the speaker.
      assert Kuroneko.Gadget.endpoints_in_use(pid) == %{in: 7, out: 2, have: have}
    end
  end
end

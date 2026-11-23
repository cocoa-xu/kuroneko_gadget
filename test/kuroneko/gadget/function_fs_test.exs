defmodule Kuroneko.Gadget.FunctionFSTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.FunctionFS
  alias Kuroneko.Gadget.FunctionFS.EP0

  defmodule Loopback do
    @moduledoc false
    use Kuroneko.Gadget.FunctionFS

    @impl FunctionFS
    def interfaces(settings) do
      bulk_in = {:in, :bulk, max_packet: Map.get(settings, :packet, 64)}

      [
        [
          name: "Loopback",
          endpoints: List.duplicate(bulk_in, Map.get(settings, :ins, 1)) ++ [{:out, :bulk}]
        ]
      ]
    end
  end

  test "a vendor interface with two bulk endpoints" do
    assert {:ok, ep0} = EP0.encode([[name: "Loopback", endpoints: [{:in, :bulk}, {:out, :bulk}]]])

    interface = <<9, 4, 0, 0, 2, 0xFF, 0, 0, 1>>
    full = [interface, <<7, 5, 0x81, 2, 64, 0, 0>>, <<7, 5, 0x02, 2, 64, 0, 0>>]
    high = [interface, <<7, 5, 0x81, 2, 0, 2, 0>>, <<7, 5, 0x02, 2, 0, 2, 0>>]

    assert ep0.descriptors ==
             IO.iodata_to_binary([
               <<3::little-32, 66::little-32, 3::little-32, 3::little-32, 3::little-32>>,
               full,
               high
             ])

    assert ep0.strings ==
             <<2::little-32, 27::little-32, 1::little-32, 1::little-32, 0x09, 0x04, "Loopback",
               0>>

    assert ep0.directions == [:in, :out]
  end

  test "interrupt and isochronous endpoints at each speed, numbered across interfaces" do
    assert {:ok, ep0} =
             EP0.encode([
               [class: 3, endpoints: [{:in, :interrupt, max_packet: 8, interval: 4}]],
               [class: 1, subclass: 2, endpoints: [{:in, :isochronous, max_packet: 192}]]
             ])

    <<3::little-32, _length::little-32, 3::little-32, 4::little-32, 4::little-32,
      descriptors::binary>> = ep0.descriptors

    assert descriptors ==
             IO.iodata_to_binary([
               <<9, 4, 0, 0, 1, 3, 0, 0, 0>>,
               <<7, 5, 0x81, 3, 8, 0, 4>>,
               <<9, 4, 1, 0, 1, 1, 2, 0, 0>>,
               <<7, 5, 0x82, 5, 192, 0, 1>>,
               <<9, 4, 0, 0, 1, 3, 0, 0, 0>>,
               <<7, 5, 0x81, 3, 8, 0, 6>>,
               <<9, 4, 1, 0, 1, 1, 2, 0, 0>>,
               <<7, 5, 0x82, 5, 192, 0, 4>>
             ])

    assert ep0.strings == <<2::little-32, 16::little-32, 0::little-32, 0::little-32>>
  end

  test "class-specific descriptors follow an interface's and an endpoint's" do
    header = <<5, 0x24, 0x00, 0x10, 0x01>>
    union = <<5, 0x24, 0x06, 0, 1>>
    endpoint_extra = <<4, 0x25, 0x01, 0>>

    assert {:ok, ep0} =
             EP0.encode([
               [
                 class: 2,
                 extra: [header <> union],
                 endpoints: [{:in, :interrupt, max_packet: 16, extra: [endpoint_extra]}]
               ]
             ])

    <<3::little-32, _length::little-32, 3::little-32, 5::little-32, 5::little-32,
      full::binary-size(30), _high::binary>> = ep0.descriptors

    assert full ==
             IO.iodata_to_binary([
               <<9, 4, 0, 0, 1, 2, 0, 0, 0>>,
               header,
               union,
               <<7, 5, 0x81, 3, 16, 0, 1>>,
               endpoint_extra
             ])

    assert EP0.encode([[extra: [<<9, 0x24>>]]]) == {:error, {:invalid_descriptor, <<9, 0x24>>}}
  end

  test "refuses what USB does not have" do
    assert {:error, {{:in, :bulk, [max_packet: 512]}, {:invalid_max_packet, 512}}} =
             EP0.encode([[endpoints: [{:in, :bulk, max_packet: 512}]]])

    assert {:error, {{:in, :interrupt, [interval: 3]}, {:invalid_interval, 3}}} =
             EP0.encode([[endpoints: [{:in, :interrupt, interval: 3}]]])

    assert EP0.encode([[endpoints: [{:both, :bulk}]]]) ==
             {:error, {:invalid_endpoint, {:both, :bulk}}}

    assert EP0.encode([[class: 256]]) == {:error, {:invalid_code, :class, 256}}
    assert EP0.encode([[speed: 1]]) == {:error, {:unknown_options, :interface, [:speed]}}
    assert EP0.encode([]) == {:error, {:invalid_interfaces, []}}
  end

  test "the events of ep0" do
    bind = <<0::64, 0, 0, 0, 0>>
    enable = <<0::64, 2, 0, 0, 0>>
    setup = <<0xC1, 0x01, 0x34, 0x12, 2, 0, 64, 0, 4, 0, 0, 0>>

    assert EP0.events(bind <> enable <> setup) == [
             :bind,
             :enable,
             {:setup,
              %{
                direction: :in,
                type: :vendor,
                recipient: :interface,
                request: 1,
                value: 0x1234,
                index: 2,
                length: 64
              }}
           ]
  end

  test "a module that uses it is a function of the type ffs, with endpoints from its interfaces" do
    assert Loopback.type() == "ffs"
    assert Loopback.default_name() == "loopback"
    assert Loopback.settings([]) == {:ok, %{}}
    assert Loopback.endpoints(%{}) == {1, 1}
    assert Loopback.endpoints(%{ins: 3}) == {3, 1}

    assert {:error, {_endpoint, {:invalid_max_packet, 100}}} = Loopback.settings(packet: 100)
    assert Kuroneko.Gadget.endpoints([:keyboard, {Loopback, ins: 2}]) == {:ok, %{in: 3, out: 1}}
    assert Loopback.handle_event(:enable, :state) == {:noreply, :state}
    assert FunctionFS.whereis(Loopback) == nil
  end
end

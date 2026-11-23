defmodule Kuroneko.Gadget.FunctionFSTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.FunctionFS

  test "the descriptors and strings of a vendor interface with two bulk endpoints" do
    assert {:ok, layout} =
             FunctionFS.layout([[name: "Loopback", endpoints: [{:in, :bulk}, {:out, :bulk}]]])

    interface = <<9, 4, 0, 0, 2, 0xFF, 0, 0, 1>>
    full = [interface, <<7, 5, 0x81, 2, 64, 0, 0>>, <<7, 5, 0x02, 2, 64, 0, 0>>]
    high = [interface, <<7, 5, 0x81, 2, 0, 2, 0>>, <<7, 5, 0x02, 2, 0, 2, 0>>]

    assert layout.descriptors ==
             IO.iodata_to_binary([
               <<3::little-32, 66::little-32, 3::little-32, 3::little-32, 3::little-32>>,
               full,
               high
             ])

    assert layout.strings ==
             <<2::little-32, 27::little-32, 1::little-32, 1::little-32, 0x09, 0x04, "Loopback",
               0>>

    assert layout.endpoints == [
             %{file: "ep1", interface: 0, direction: :in, type: :bulk},
             %{file: "ep2", interface: 0, direction: :out, type: :bulk}
           ]
  end

  test "interrupt and isochronous endpoints at each speed, numbered across interfaces" do
    assert {:ok, layout} =
             FunctionFS.layout([
               [class: 3, endpoints: [{:in, :interrupt, max_packet: 8, interval: 4}]],
               [class: 1, subclass: 2, endpoints: [{:in, :isochronous, max_packet: 192}]]
             ])

    <<3::little-32, _length::little-32, 3::little-32, 4::little-32, 4::little-32,
      descriptors::binary>> = layout.descriptors

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

    assert layout.strings == <<2::little-32, 16::little-32, 0::little-32, 0::little-32>>
    assert Enum.map(layout.endpoints, &{&1.file, &1.interface}) == [{"ep1", 0}, {"ep2", 1}]
  end

  test "refuses what USB does not have" do
    assert {:error, {:invalid_max_packet, _}} =
             FunctionFS.layout([[endpoints: [{:in, :bulk, max_packet: 512}]]])

    assert {:error, {:invalid_interval, _}} =
             FunctionFS.layout([[endpoints: [{:in, :interrupt, interval: 3}]]])

    assert {:error, {:invalid_endpoint, {:both, :bulk}}} =
             FunctionFS.layout([[endpoints: [{:both, :bulk}]]])

    assert {:error, {:invalid_class, 256}} = FunctionFS.layout([[class: 256]])
    assert {:error, {:unknown_options, :interface, [:speed]}} = FunctionFS.layout([[speed: 1]])
    assert {:error, {:invalid_interfaces, []}} = FunctionFS.layout([])
  end

  test "the events of ep0" do
    bind = <<0::64, 0, 0, 0, 0>>
    enable = <<0::64, 2, 0, 0, 0>>
    setup = <<0xC1, 0x01, 0x34, 0x12, 2, 0, 64, 0, 4, 0, 0, 0>>

    assert FunctionFS.events(bind <> enable <> setup <> <<1, 2>>) == [
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
end

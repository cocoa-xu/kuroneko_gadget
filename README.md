# Kuroneko.Gadget

The USB side of a KVM, for Elixir on Linux: the devices the target computer
sees when the KVM is plugged into it, as the functions of a USB gadget in
configfs.

Linux sorts gadget functions by driver, and so does this library, with a
module for each:

* `Kuroneko.Gadget.HID` - keyboards, mice and any HID device, by its report
  descriptor. `Kuroneko.Gadget.Input` types and points with the KVM's
  keyboard and mice (an absolute pointer, a pen or a ten-finger touch
  screen, and a relative boot mouse), and wakes a target that sleeps.
* `Kuroneko.Gadget.MassStorage` - drives that hold image files, as removable
  disks or as CDs, DVDs and BDs, audio and mixed-mode CDs too
* `Kuroneko.Gadget.UAC2` - a sound card, a microphone and a speaker for the
  target, mono to 7.1, 16 to 32 bits, at the rates the target chooses from
* `Kuroneko.Gadget.NCM` - a network adapter, whose addresses stay the same
  across boots
* `Kuroneko.Gadget.ACM` - a serial port
* `Kuroneko.Gadget.FunctionFS` - a function written in Elixir

`Kuroneko.Gadget` puts them on the gadget within the endpoints the device
controller has, and changes them while the KVM runs.

It is part of [Kuroneko](https://github.com/cocoa-xu/kuroneko), an open KVM.
Board libraries give it their board's settings, such as
[`nano_kvm_go`](https://github.com/cocoa-xu/nano_kvm_go) for the Sipeed
NanoKVM-Go.

## Installation

```elixir
def deps do
  [
    {:kuroneko_gadget, github: "cocoa-xu/kuroneko_gadget", tag: "v0.3.0"}
  ]
end
```

The system sets up the gadget at boot and binds it to the device controller,
as the NanoKVM-Go's Nerves system does. Its kernel needs configfs gadgets
with the functions you use, such as `CONFIG_USB_CONFIGFS_F_HID`. DVDs and
BDs, CDs of tracks and asking the target to eject a disc need the mass
storage function's `profile`, `tracks` and `eject_request` attributes,
which Kuroneko's kernel (`cocoa-xu/linux-ax620e`) adds.

FunctionFS functions run a small C program, `kuroneko_ffs`, which the
library builds with `elixir_make` on Linux, Nerves cross-compiling it; on
other hosts nothing is built.

## Usage

```elixir
children = [
  {Kuroneko.Gadget, functions: [:keyboard, :mouse, :relative_mouse, :storage]},
  Kuroneko.Gadget.Input
]

Supervisor.start_link(children, strategy: :one_for_one)
```

On a board, start the gadget with the board's settings: the endpoints and
largest packets its USB controller takes, the names the target sees, and
how it keeps the network's addresses.

```elixir
{Kuroneko.Gadget, NanoKVMGo.USB.gadget_options() ++ [functions: [:keyboard, :mouse]]}
```

### Keyboard and mouse

```elixir
Kuroneko.Gadget.Input.key("KeyA", :down)
Kuroneko.Gadget.Input.key("KeyA", :up)
Kuroneko.Gadget.Input.type("Hello!\n")
Kuroneko.Gadget.Input.pointer(x: 0.5, y: 0.5, buttons: [:left])
Kuroneko.Gadget.Input.relative(dx: 10, dy: -5, wheel: 1)
Kuroneko.Gadget.Input.release_all()
```

Keys are named like the browser's `KeyboardEvent.code`, so web clients can
pass them through. `{:mouse, mode: :stylus}` or `{:mouse, mode: :touch}`
makes the absolute pointer a pen or a touch screen, for Android and iPadOS
targets.

### Mass storage

```elixir
Kuroneko.Gadget.MassStorage.insert("/data/images/debian.iso")
Kuroneko.Gadget.MassStorage.medium()
#=> {:ok, %{image: "/data/images/debian.iso", as: :dvd, read_only: true, tracks: nil}}
Kuroneko.Gadget.MassStorage.eject()
```

An image of ISO 9660 or UDF goes in as a DVD by default, any other as a
removable disk.

### Microphone and speaker

```elixir
{Kuroneko.Gadget,
 functions: [
   {:microphone, channels: 1, rates: [48_000, 44_100]},
   {:speaker, channels: 6, rates: [48_000, 96_000], sample_bits: 24}
 ]}
```

The sound itself goes through ALSA, the card `UAC2Gadget`: on the
NanoKVM-Go, `NanoKVMGo.Microphone` plays to the target's microphone and
`NanoKVMGo.Audio` with `source: :usb` records its speaker.

### The USB network

```elixir
Kuroneko.Gadget.network()
#=> {:ok, %{interface: "usb0", device_address: "9e:9f:51:11:f7:b2", host_address: "7a:78:1f:1f:1d:dd", ...}}

:ok = Kuroneko.Gadget.set_network_addresses(host_address: "02:12:34:56:78:9a")
```

### Functions of your own

Any HID device, by its report descriptor, or any other function module:

```elixir
Kuroneko.Gadget.configure([
  :keyboard,
  {Kuroneko.Gadget.HID, name: "pad", descriptor: %{report_desc: pad, report_length: 4}},
  Kuroneko.Gadget.ACM
])
```

`Kuroneko.Gadget.FunctionFS` writes a whole USB function in Elixir, its
descriptors as data and its transfers as events, and
`Kuroneko.Gadget.Function` adds another of the kernel's functions.

## Changing USB functions

Adding or removing functions, or changing the network's addresses, takes
the device off the bus for a moment, and the keyboard and mice with it. Each
function takes endpoints of the device controller, which has few: a change
it refuses leaves the functions as they were.

## License

Apache-2.0, see [LICENSE](LICENSE).

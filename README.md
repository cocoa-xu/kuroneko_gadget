# Kuroneko.Gadget

The USB side of a KVM, for Elixir on Linux: what the target computer sees
when the KVM is plugged into it.

* **Keyboard and mouse** - a boot keyboard, an absolute pointer (a mouse, a
  pen or a ten-finger touch screen) and a relative boot mouse, waking the
  target from sleep
* **Mass storage** - disk and CD-ROM images
* **Two-way USB audio** - a microphone and a speaker for the target, each
  mono to 7.1, 16 to 32 bits, at the rates the target chooses from
* **USB network** - the MAC addresses of the network function, to read and
  to change
* **The connection** - whether the target has set the device up, and at what
  speed

It adds and removes the functions of a USB gadget in configfs, with the
kernel's own function drivers (HID, mass storage, UAC2): pure Elixir, no
programs or NIFs.

It is part of [Kuroneko](https://github.com/cocoa-xu/kuroneko), an open KVM.
Board libraries give it their board's settings, such as
[`nano_kvm_go`](https://github.com/cocoa-xu/nano_kvm_go) for the Sipeed
NanoKVM-Go.

## Installation

```elixir
def deps do
  [
    {:kuroneko_gadget, github: "cocoa-xu/kuroneko_gadget", tag: "v0.2.0"}
  ]
end
```

The system sets up the gadget at boot and binds it to the device controller,
as the NanoKVM-Go's Nerves system does. Its kernel needs configfs gadgets
with the functions you use: `CONFIG_USB_CONFIGFS_F_HID`,
`CONFIG_USB_CONFIGFS_MASS_STORAGE`, `CONFIG_USB_CONFIGFS_F_UAC2`.

## Usage

```elixir
children = [
  {Kuroneko.Gadget, functions: [:keyboard, :mouse, :relative_mouse, :storage]},
  Kuroneko.Gadget.HID
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The functions go on the only gadget in configfs, or the one in the
application environment:

```elixir
config :kuroneko_gadget, gadget: "/sys/kernel/config/usb_gadget/g1"
```

On a board, start the gadget with the board's settings: the largest packets
its USB controller takes, the names the target sees, and how it keeps the
network's addresses.

```elixir
{Kuroneko.Gadget, NanoKVMGo.USB.gadget_options() ++ [functions: [:keyboard, :mouse]]}
```

### Keyboard and mouse

```elixir
Kuroneko.Gadget.HID.key("KeyA", :down)
Kuroneko.Gadget.HID.key("KeyA", :up)
Kuroneko.Gadget.HID.type("Hello!\n")
Kuroneko.Gadget.HID.pointer(x: 0.5, y: 0.5, buttons: [:left])
Kuroneko.Gadget.HID.relative(dx: 10, dy: -5, wheel: 1)
Kuroneko.Gadget.HID.release_all()
```

Keys are named like the browser's `KeyboardEvent.code`, so web clients can
pass them through. `{:mouse, mode: :stylus}` or `{:mouse, mode: :touch}`
turns the absolute pointer into a pen or a touch screen, for Android and
iPadOS targets; `Kuroneko.Gadget.HID.touch/2` sends up to ten touches. The
relative mouse is a boot mouse, for BIOS setups and games. Input wakes a
target that sleeps.

### Mass storage

```elixir
Kuroneko.Gadget.Storage.insert("/data/images/debian.iso")
Kuroneko.Gadget.Storage.medium()
#=> {:ok, %{image: "/data/images/debian.iso", cdrom: true, read_only: true}}
Kuroneko.Gadget.Storage.eject()
```

ISO images become CD-ROMs by default, other images drives.

### USB microphone and speaker

With the `:microphone` and `:speaker` functions the target computer sees a
USB sound card, stereo, 16-bit and 48 kHz by default. Each direction takes
its channels, the rates the target can choose from (starting with the
first) and its sample size:

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
`Kuroneko.Gadget.validate/2` tells whether the device controller can carry
a format.

### The USB network

The target computer reaches the device over USB too, through a network
adapter it sees: the network function the system set up.

```elixir
Kuroneko.Gadget.network()
#=> {:ok, %{interface: "usb0", device_address: "9e:9f:51:11:f7:b2", host_address: "7a:78:1f:1f:1d:dd", ...}}

:ok = Kuroneko.Gadget.set_network_addresses(host_address: "02:12:34:56:78:9a")
```

The `:network` option's `:persist` function keeps new addresses for the next
boots, where the system reads them.

### The connection

```elixir
Kuroneko.Gadget.connection()
#=> {:ok, %{state: :configured, speed: :high_speed, controller: "8000000.usb"}}
```

## Changing USB functions

Adding or removing functions, or changing the network's addresses,
disconnects the device from the target computer for a moment, and with the
keyboard and mice the target computer takes input from it. Each function
takes endpoints of the device controller, which has few: a change it
refuses leaves the functions as they were.

## License

Apache-2.0, see [LICENSE](LICENSE).

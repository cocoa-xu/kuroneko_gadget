# Changelog

## Unreleased

* Several functions of a kind, each with a name: two storage functions,
  two networks, two keyboards; `Kuroneko.Gadget.instances/1` tells them
* A storage function with several logical units, the kernel's LUNs, each a
  drive the target sees: `{:storage, luns: 3}`, up to 16 on the endpoints of
  one; a change of their number keeps the media of the LUNs that stay.
  `Kuroneko.Gadget.Storage` takes `:storage` and `:lun` for one, and tells
  them all with `luns/1` and `media/1`
* Network functions as KVM functions when asked for with `:network`, other
  networks with addresses that stay across boots; `instances/1` tells each
  network's interface and addresses
* The device controller's endpoints as a budget, `:endpoints`, and
  `Kuroneko.Gadget.endpoints/1`; `endpoints_in_use/1` tells how many the
  gadget's functions take now
* `Kuroneko.Gadget.Storage`: the optical drive holds a CD, a DVD or a BD
  (`disc:`, a DVD by default), so that images over 2.3 GB, which a CD
  cannot address, go in whole. It needs the kernel's `profile` attribute
  on the LUN; without it the drive holds CDs, as before

## v0.1.0 (2026-11-21)

First version, moved out of `nano_kvm_go` (where it was `NanoKVMGo.USB`,
`NanoKVMGo.HID` and `NanoKVMGo.Storage`):

* `Kuroneko.Gadget`: the keyboard, mouse, relative mouse, mass storage,
  microphone and speaker functions on a configfs gadget the system set up;
  the formats of the USB audio, the network's addresses, the state and
  speed of the connection
* `Kuroneko.Gadget.HID`: keyboard, mouse, pen and touch input, waking a
  target that sleeps
* `Kuroneko.Gadget.Storage`: disk images as a removable drive or a CD-ROM
* What was the NanoKVM-Go's is now an option: the gadget (the only one in
  configfs by default), the names the target sees, the largest packets of
  the device controller, the network function and how its addresses are
  kept

defmodule Kuroneko.Gadget.StorageTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    gadget = Path.join(tmp_dir, "gadget")
    lun = Path.join(gadget, "functions/mass_storage.disk/lun.0")
    File.mkdir_p!(lun)

    for attribute <- ["file", "profile", "ro", "tracks"],
        do: File.write!(Path.join(lun, attribute), "")

    File.write!(Path.join(lun, "cdrom"), "0")

    udc_class = Path.join(tmp_dir, "udc")
    File.mkdir_p!(Path.join(udc_class, "dwc3"))

    iso = Path.join(tmp_dir, "install.ISO")
    disk = Path.join(tmp_dir, "disk.img")
    File.write!(iso, "")
    File.write!(disk, "")

    %{gadget: gadget, lun: lun, iso: iso, disk: disk, udc_class: udc_class}
  end

  defp soft_connect(udc_class), do: File.read(Path.join(udc_class, "dwc3/soft_connect"))

  test "an ISO image is a read-only DVD unless asked", %{gadget: gadget, lun: lun, iso: iso} do
    assert :ok = Storage.insert(iso, gadget: gadget)

    assert Storage.medium(gadget: gadget) ==
             {:ok, %{image: iso, cdrom: true, disc: :dvd, read_only: true, tracks: nil}}

    assert :ok = Storage.insert(iso, gadget: gadget, disc: :bd)
    assert File.read!(Path.join(lun, "profile")) == "bd"
    assert {:ok, %{disc: :bd}} = Storage.medium(gadget: gadget)

    assert :ok = Storage.insert(iso, gadget: gadget, disc: :cd)
    assert {:ok, %{disc: :cd}} = Storage.medium(gadget: gadget)
  end

  test "only CDs without the kernel's profile attribute", %{gadget: gadget, lun: lun, iso: iso} do
    File.rm!(Path.join(lun, "profile"))
    assert :ok = Storage.insert(iso, gadget: gadget)
    assert {:ok, %{disc: :cd}} = Storage.medium(gadget: gadget)
    assert Storage.insert(iso, gadget: gadget, disc: :dvd) == {:error, :disc_unsupported}
  end

  test "another image is a writable disk unless asked", %{gadget: gadget, disk: disk} do
    assert :ok = Storage.insert(disk, gadget: gadget)

    assert Storage.medium(gadget: gadget) ==
             {:ok, %{image: disk, cdrom: false, disc: nil, read_only: false, tracks: nil}}

    assert :ok = Storage.insert(disk, gadget: gadget, read_only: true)
    assert {:ok, %{read_only: true}} = Storage.medium(gadget: gadget)
  end

  test "ejecting takes the medium out, a medium the computer has not locked as asked",
       %{gadget: gadget, lun: lun, disk: disk} do
    assert :ok = Storage.insert(disk, gadget: gadget)
    assert :ok = Storage.eject(gadget: gadget)
    refute File.exists?(Path.join(lun, "forced_eject"))
    assert Storage.medium(gadget: gadget) == {:ok, nil}
    assert :ok = Storage.eject(gadget: gadget)
  end

  test "a CD of tracks: audio and data, with their sectors where the image has them",
       %{gadget: gadget, lun: lun, tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "game.bin")
    File.write!(bin, "")

    tracks = [
      %{number: 1, mode: :mode1, size: 2352, offset: 0, flags: [:copy_permitted]},
      %{number: 2, mode: :audio, size: 2352, offset: 1_234_800, pregap: 150},
      %{number: 3, mode: :audio, size: 2352, offset: 2_469_600, flags: [:pre_emphasis]}
    ]

    assert :ok = Storage.insert(bin, gadget: gadget, tracks: tracks, replug: false)

    assert File.read!(Path.join(lun, "tracks")) ==
             "1 1 6 2352 0 0\n2 0 0 2352 150 1234800\n3 0 1 2352 0 2469600\n"

    assert {:ok, %{cdrom: true, disc: :cd, read_only: true, tracks: read}} =
             Storage.medium(gadget: gadget)

    assert read == [
             %{
               number: 1,
               mode: :mode1,
               size: 2352,
               pregap: 0,
               offset: 0,
               flags: [:copy_permitted]
             },
             %{number: 2, mode: :audio, size: 2352, pregap: 150, offset: 1_234_800, flags: []},
             %{
               number: 3,
               mode: :audio,
               size: 2352,
               pregap: 0,
               offset: 2_469_600,
               flags: [:pre_emphasis]
             }
           ]

    for {bad, reason} <- [
          {[%{number: 1, mode: :audio, size: 2048, offset: 0}], 1},
          {[
             %{number: 1, mode: :mode1, size: 2048, offset: 0},
             %{number: 3, mode: :audio, size: 2352, offset: 9}
           ], 3},
          {[%{number: 1, mode: :audio, size: 2352, offset: 0, flags: [:scms]}], 1},
          {[], :none}
        ],
        do:
          assert(
            Storage.insert(bin, gadget: gadget, tracks: bad) ==
              {:error, {:invalid_tracks, reason}}
          )

    assert Storage.insert(bin, gadget: gadget, tracks: tracks, disc: :dvd) ==
             {:error, {:invalid_tracks, :not_a_cd}}

    File.rm!(Path.join(lun, "tracks"))
    assert Storage.insert(bin, gadget: gadget, tracks: tracks) == {:error, :tracks_unsupported}
  end

  test "the computer sees the drive anew when it turns optical or removable",
       %{gadget: gadget, iso: iso, disk: disk, udc_class: udc_class} do
    File.write!(Path.join(gadget, "UDC"), "dwc3\n")
    opts = [gadget: gadget, udc_class: udc_class, replug_ms: 0]

    assert :ok = Storage.insert(disk, opts)
    assert soft_connect(udc_class) == {:error, :enoent}

    assert :ok = Storage.insert(iso, opts)
    assert soft_connect(udc_class) == {:ok, "connect"}

    File.rm!(Path.join(udc_class, "dwc3/soft_connect"))
    assert :ok = Storage.insert(iso, opts)
    assert :ok = Storage.eject(opts)
    assert soft_connect(udc_class) == {:error, :enoent}

    assert :ok = Storage.insert(iso, opts ++ [replug: true])
    assert soft_connect(udc_class) == {:ok, "connect"}

    File.rm!(Path.join(udc_class, "dwc3/soft_connect"))
    assert :ok = Storage.insert(disk, opts ++ [replug: false])
    assert soft_connect(udc_class) == {:error, :enoent}
  end

  test "errors without an image or a storage function", %{gadget: gadget, tmp_dir: tmp_dir} do
    assert Storage.insert(Path.join(tmp_dir, "missing.img"), gadget: gadget) == {:error, :enoent}

    assert Storage.insert(Path.join(tmp_dir, "disk.img"), gadget: tmp_dir) ==
             {:error, :no_storage}

    assert Storage.medium(gadget: tmp_dir) == {:error, :no_storage}
  end

  test "a LUN of several, and another storage function", %{gadget: gadget, iso: iso, disk: disk} do
    for lun <- ["functions/mass_storage.disk/lun.1", "functions/mass_storage.boot/lun.0"] do
      dir = Path.join(gadget, lun)
      File.mkdir_p!(dir)

      for attribute <- ["file", "cdrom", "profile", "ro", "tracks"],
          do: File.write!(Path.join(dir, attribute), "")
    end

    assert Storage.luns(gadget: gadget) == 2
    assert :ok = Storage.insert(iso, gadget: gadget, lun: 1, disc: :cd)
    assert :ok = Storage.insert(disk, gadget: gadget, storage: "boot")

    assert Storage.media(gadget: gadget) == [
             nil,
             %{image: iso, cdrom: true, disc: :cd, read_only: true, tracks: nil}
           ]

    assert {:ok, %{image: ^disk, cdrom: false}} = Storage.medium(gadget: gadget, storage: "boot")
    assert :ok = Storage.eject(gadget: gadget, lun: 1)
    assert Storage.media(gadget: gadget) == [nil, nil]
  end
end

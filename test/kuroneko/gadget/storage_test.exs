defmodule Kuroneko.Gadget.StorageTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.Storage

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    gadget = Path.join(tmp_dir, "gadget")
    lun = Path.join(gadget, "functions/mass_storage.disk/lun.0")
    File.mkdir_p!(lun)

    for attribute <- ["file", "cdrom", "profile", "ro"],
        do: File.write!(Path.join(lun, attribute), "")

    iso = Path.join(tmp_dir, "install.ISO")
    disk = Path.join(tmp_dir, "disk.img")
    File.write!(iso, "")
    File.write!(disk, "")

    %{gadget: gadget, lun: lun, iso: iso, disk: disk}
  end

  test "an ISO image is a read-only DVD unless asked", %{gadget: gadget, lun: lun, iso: iso} do
    assert :ok = Storage.insert(iso, gadget: gadget)

    assert Storage.medium(gadget: gadget) ==
             {:ok, %{image: iso, cdrom: true, disc: :dvd, read_only: true}}

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
             {:ok, %{image: disk, cdrom: false, disc: nil, read_only: false}}

    assert :ok = Storage.insert(disk, gadget: gadget, read_only: true)
    assert {:ok, %{read_only: true}} = Storage.medium(gadget: gadget)
  end

  test "ejecting forces the medium out", %{gadget: gadget, lun: lun, disk: disk} do
    assert :ok = Storage.insert(disk, gadget: gadget)
    assert :ok = Storage.eject(gadget: gadget)
    assert File.read!(Path.join(lun, "forced_eject")) == "1"
    assert Storage.medium(gadget: gadget) == {:ok, nil}
    assert :ok = Storage.eject(gadget: gadget)
  end

  test "errors without an image or a storage function", %{gadget: gadget, tmp_dir: tmp_dir} do
    assert Storage.insert(Path.join(tmp_dir, "missing.img"), gadget: gadget) == {:error, :enoent}

    assert Storage.insert(Path.join(tmp_dir, "disk.img"), gadget: tmp_dir) ==
             {:error, :no_storage}

    assert Storage.medium(gadget: tmp_dir) == {:error, :no_storage}
  end

  test "a drive of several, and another storage function", %{gadget: gadget, iso: iso, disk: disk} do
    for lun <- ["functions/mass_storage.disk/lun.1", "functions/mass_storage.boot/lun.0"] do
      dir = Path.join(gadget, lun)
      File.mkdir_p!(dir)

      for attribute <- ["file", "cdrom", "profile", "ro"],
          do: File.write!(Path.join(dir, attribute), "")
    end

    assert Storage.drives(gadget: gadget) == 2
    assert :ok = Storage.insert(iso, gadget: gadget, drive: 1, disc: :cd)
    assert :ok = Storage.insert(disk, gadget: gadget, storage: "boot")

    assert Storage.media(gadget: gadget) == [
             nil,
             %{image: iso, cdrom: true, disc: :cd, read_only: true}
           ]

    assert {:ok, %{image: ^disk, cdrom: false}} = Storage.medium(gadget: gadget, storage: "boot")
    assert :ok = Storage.eject(gadget: gadget, drive: 1)
    assert Storage.media(gadget: gadget) == [nil, nil]
  end
end

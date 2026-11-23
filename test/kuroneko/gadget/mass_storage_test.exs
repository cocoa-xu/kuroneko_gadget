defmodule Kuroneko.Gadget.MassStorageTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Gadget.MassStorage

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

    iso = Path.join(tmp_dir, "install.img")
    File.write!(iso, :binary.copy(<<0>>, 32_769) <> "CD001" <> :binary.copy(<<0>>, 2042))
    disk = Path.join(tmp_dir, "disk.iso")
    File.write!(disk, :binary.copy(<<0>>, 65_536))

    %{gadget: gadget, lun: lun, iso: iso, disk: disk, udc_class: udc_class}
  end

  defp soft_connect(udc_class), do: File.read(Path.join(udc_class, "dwc3/soft_connect"))

  test "an image of ISO 9660 or UDF is a read-only DVD unless asked, whatever its name",
       %{gadget: gadget, lun: lun, iso: iso, tmp_dir: tmp_dir} do
    assert :ok = MassStorage.insert(iso, gadget: gadget)

    assert MassStorage.medium(gadget: gadget) ==
             {:ok, %{image: iso, as: :dvd, read_only: true, tracks: nil}}

    assert :ok = MassStorage.insert(iso, gadget: gadget, as: :bd)
    assert File.read!(Path.join(lun, "profile")) == "bd"
    assert {:ok, %{as: :bd}} = MassStorage.medium(gadget: gadget)

    assert :ok = MassStorage.insert(iso, gadget: gadget, as: :cd)
    assert {:ok, %{as: :cd}} = MassStorage.medium(gadget: gadget)

    udf = Path.join(tmp_dir, "udf.bin")
    File.write!(udf, :binary.copy(<<0>>, 32_769) <> "BEA01" <> :binary.copy(<<0>>, 2042))
    assert :ok = MassStorage.insert(udf, gadget: gadget)
    assert {:ok, %{as: :dvd}} = MassStorage.medium(gadget: gadget)
  end

  test "only CDs without the kernel's profile attribute", %{gadget: gadget, lun: lun, iso: iso} do
    File.rm!(Path.join(lun, "profile"))
    assert :ok = MassStorage.insert(iso, gadget: gadget)
    assert {:ok, %{as: :cd}} = MassStorage.medium(gadget: gadget)
    assert MassStorage.insert(iso, gadget: gadget, as: :dvd) == {:error, :disc_unsupported}
  end

  test "another image is a writable disk unless asked", %{gadget: gadget, disk: disk} do
    assert :ok = MassStorage.insert(disk, gadget: gadget)

    assert MassStorage.medium(gadget: gadget) ==
             {:ok, %{image: disk, as: :disk, read_only: false, tracks: nil}}

    assert :ok = MassStorage.insert(disk, gadget: gadget, read_only: true)
    assert {:ok, %{read_only: true}} = MassStorage.medium(gadget: gadget)
  end

  test "options it does not know or values it does not take raise", %{gadget: gadget, disk: disk} do
    assert_raise ArgumentError, fn -> MassStorage.insert(disk, gadget: gadget, readonly: true) end
    assert_raise ArgumentError, fn -> MassStorage.insert(disk, gadget: gadget, as: :blu_ray) end

    assert_raise ArgumentError, fn ->
      MassStorage.insert(disk, gadget: gadget, read_only: :yes)
    end

    assert {:ok, nil} = MassStorage.medium(gadget: gadget)
  end

  test "ejecting takes the medium out, a medium the computer has not locked as asked",
       %{gadget: gadget, lun: lun, disk: disk} do
    assert :ok = MassStorage.insert(disk, gadget: gadget)
    assert :ok = MassStorage.eject(gadget: gadget)
    refute File.exists?(Path.join(lun, "forced_eject"))
    assert MassStorage.medium(gadget: gadget) == {:ok, nil}
    assert :ok = MassStorage.eject(gadget: gadget)
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

    assert :ok = MassStorage.insert(bin, gadget: gadget, tracks: tracks, replug: false)

    assert File.read!(Path.join(lun, "tracks")) ==
             "1 1 6 2352 0 0\n2 0 0 2352 150 1234800\n3 0 1 2352 0 2469600\n"

    assert {:ok, %{as: :cd, read_only: true, tracks: read}} = MassStorage.medium(gadget: gadget)

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

    wrong_size = %{number: 1, mode: :audio, size: 2048, offset: 0}
    skipped = %{number: 3, mode: :audio, size: 2352, offset: 9}
    unknown_flag = %{number: 1, mode: :audio, size: 2352, offset: 0, flags: [:scms]}

    for {bad, reason} <- [
          {[wrong_size], wrong_size},
          {[%{number: 1, mode: :mode1, size: 2048, offset: 0}, skipped], skipped},
          {[unknown_flag], unknown_flag},
          {[], []}
        ],
        do:
          assert(
            MassStorage.insert(bin, gadget: gadget, tracks: bad) ==
              {:error, {:invalid_tracks, reason}}
          )

    assert MassStorage.insert(bin, gadget: gadget, tracks: tracks, as: :dvd) ==
             {:error, {:invalid_tracks, {:as, :dvd}}}

    File.rm!(Path.join(lun, "tracks"))

    assert MassStorage.insert(bin, gadget: gadget, tracks: tracks) ==
             {:error, :tracks_unsupported}
  end

  test "the computer sees the drive anew when it turns optical or removable",
       %{gadget: gadget, iso: iso, disk: disk, udc_class: udc_class} do
    File.write!(Path.join(gadget, "UDC"), "dwc3\n")

    server =
      start_supervised!(
        {Kuroneko.Gadget, gadget: gadget, udc_class: udc_class, replug_ms: 0, name: nil}
      )

    opts = [gadget: gadget, server: server]

    assert :ok = MassStorage.insert(disk, opts)
    assert soft_connect(udc_class) == {:error, :enoent}

    assert :ok = MassStorage.insert(iso, opts)
    assert soft_connect(udc_class) == {:ok, "connect"}

    File.rm!(Path.join(udc_class, "dwc3/soft_connect"))
    assert :ok = MassStorage.insert(iso, opts)
    assert :ok = MassStorage.eject(opts)
    assert soft_connect(udc_class) == {:error, :enoent}

    assert :ok = MassStorage.insert(iso, opts ++ [replug: true])
    assert soft_connect(udc_class) == {:ok, "connect"}

    File.rm!(Path.join(udc_class, "dwc3/soft_connect"))
    assert :ok = MassStorage.insert(disk, opts ++ [replug: false])
    assert soft_connect(udc_class) == {:error, :enoent}
  end

  test "errors without an image or a storage function", %{gadget: gadget, tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing.img")
    assert MassStorage.insert(missing, gadget: gadget) == {:error, {:no_image, missing}}

    assert MassStorage.insert(Path.join(tmp_dir, "disk.iso"), gadget: tmp_dir) ==
             {:error, :no_storage}

    assert MassStorage.medium(gadget: tmp_dir) == {:error, :no_storage}
  end

  test "a LUN of several, and another storage function", %{gadget: gadget, iso: iso, disk: disk} do
    for lun <- ["functions/mass_storage.disk/lun.1", "functions/mass_storage.boot/lun.0"] do
      dir = Path.join(gadget, lun)
      File.mkdir_p!(dir)

      for attribute <- ["file", "cdrom", "profile", "ro", "tracks"],
          do: File.write!(Path.join(dir, attribute), "")
    end

    assert MassStorage.lun_count(gadget: gadget) == 2
    assert :ok = MassStorage.insert(iso, gadget: gadget, lun: 1, as: :cd)
    assert :ok = MassStorage.insert(disk, gadget: gadget, name: "boot")

    assert MassStorage.media(gadget: gadget) == [
             nil,
             %{image: iso, as: :cd, read_only: true, tracks: nil}
           ]

    assert {:ok, %{image: ^disk, as: :disk}} = MassStorage.medium(gadget: gadget, name: "boot")
    assert :ok = MassStorage.eject(gadget: gadget, lun: 1)
    assert MassStorage.media(gadget: gadget) == [nil, nil]
  end
end

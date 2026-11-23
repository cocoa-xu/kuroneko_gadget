defmodule Kuroneko.Gadget.Storage do
  @moduledoc """
  Disk images for the target computer, through the `:storage` function of
  `Kuroneko.Gadget`: a removable drive, or a CD-ROM drive, with an image file as
  its medium.

      Kuroneko.Gadget.Storage.insert("/data/images/debian.iso")
      Kuroneko.Gadget.Storage.medium()
      #=> {:ok, %{image: "/data/images/debian.iso", cdrom: true, disc: :dvd, read_only: true}}
      Kuroneko.Gadget.Storage.eject()

  ISO images go in an optical drive by default, other images a removable
  drive. The target computer can write to an image that is not read-only.
  Keep images in `/data`, the writable partition of a Nerves device.

  The optical drive tells the target what disc it holds: a CD, a DVD or a
  BD. A CD is addressed in minutes, seconds and frames too, and ends at
  255:59:74, about 2.3 GB; DVDs and BDs do not have that limit. Choosing
  the disc needs the LUN's `profile` attribute, which the Linux kernel has
  with Kuroneko's patch; without it the drive holds CDs only.

  The functions take a `:gadget` option, `Kuroneko.Gadget.default_gadget/0`
  by default.
  """

  @typedoc "The image in the drive and how the target computer sees it."
  @type medium() :: %{
          image: Path.t(),
          cdrom: boolean(),
          disc: disc() | nil,
          read_only: boolean()
        }

  @typedoc "The disc in the optical drive."
  @type disc() :: :cd | :dvd | :bd

  @type insert_option() ::
          {:cdrom, boolean()} | {:disc, disc()} | {:read_only, boolean()} | {:gadget, Path.t()}

  @doc """
  Puts an image in the drive, in place of the one there.

  ## Options

    * `:cdrom` - an optical drive instead of a removable disk; by default for
      images ending in `.iso`
    * `:disc` - the disc in the optical drive, `:cd`, `:dvd` or `:bd`; `:dvd`
      by default, as desktop systems mount ISO images. Without the kernel's
      `profile` attribute only `:cd` goes, and is the default
    * `:read_only` - the target computer cannot write; by default for optical
      drives
  """
  @spec insert(Path.t(), [insert_option()]) :: :ok | {:error, term()}
  def insert(image, opts \\ []) do
    image = Path.expand(image)
    cdrom = Keyword.get_lazy(opts, :cdrom, fn -> iso?(image) end)
    read_only = Keyword.get(opts, :read_only, cdrom)
    lun = lun(opts)

    with :ok <- check_lun(lun),
         :ok <- check_image(image),
         :ok <- remove_medium(lun),
         :ok <- write(lun, "cdrom", flag(cdrom)),
         :ok <- write_disc(lun, cdrom, opts[:disc]),
         :ok <- write(lun, "ro", flag(read_only)) do
      write(lun, "file", image)
    end
  end

  @doc """
  Takes the image out of the drive, even when the target computer holds it.
  """
  @spec eject([{:gadget, Path.t()}]) :: :ok | {:error, term()}
  def eject(opts \\ []) do
    lun = lun(opts)

    with :ok <- check_lun(lun), do: remove_medium(lun)
  end

  @doc """
  The image in the drive, `nil` when there is none.
  """
  @spec medium([{:gadget, Path.t()}]) :: {:ok, medium() | nil} | {:error, term()}
  def medium(opts \\ []) do
    lun = lun(opts)

    with :ok <- check_lun(lun),
         {:ok, image} <- read(lun, "file"),
         {:ok, cdrom} <- read(lun, "cdrom"),
         {:ok, read_only} <- read(lun, "ro") do
      cdrom = cdrom == "1"

      if image == "",
        do: {:ok, nil},
        else:
          {:ok,
           %{
             image: image,
             cdrom: cdrom,
             disc: if(cdrom, do: disc(lun)),
             read_only: read_only == "1"
           }}
    end
  end

  @discs %{cd: "cd", dvd: "dvd", bd: "bd"}

  defp write_disc(_lun, false, _disc), do: :ok

  defp write_disc(lun, true, disc) do
    cond do
      File.exists?(Path.join(lun, "profile")) and Map.has_key?(@discs, disc || :dvd) ->
        write(lun, "profile", @discs[disc || :dvd])

      disc in [nil, :cd] ->
        :ok

      true ->
        {:error, :disc_unsupported}
    end
  end

  defp disc(lun) do
    case read(lun, "profile") do
      {:ok, "dvd"} -> :dvd
      {:ok, "bd"} -> :bd
      _cd_or_none -> :cd
    end
  end

  # forced_eject works even when the host has locked the medium (SCSI
  # "prevent removal"), where writing an empty file name fails.
  defp remove_medium(lun) do
    with {:ok, image} when image != "" <- read(lun, "file"),
         :ok <- write(lun, "forced_eject", "1"),
         {:ok, image} when image != "" <- read(lun, "file") do
      write(lun, "file", "")
    else
      {:ok, ""} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lun(opts), do: Path.join(Kuroneko.Gadget.function_dir(:storage, opts), "lun.0")

  defp check_lun(lun) do
    if File.dir?(lun), do: :ok, else: {:error, :no_storage}
  end

  defp check_image(image) do
    if File.regular?(image), do: :ok, else: {:error, :enoent}
  end

  defp iso?(image), do: String.downcase(Path.extname(image)) == ".iso"

  defp flag(true), do: "1"
  defp flag(false), do: "0"

  defp read(lun, attribute) do
    with {:ok, value} <- File.read(Path.join(lun, attribute)), do: {:ok, String.trim(value)}
  end

  defp write(lun, attribute, value), do: File.write(Path.join(lun, attribute), value)
end

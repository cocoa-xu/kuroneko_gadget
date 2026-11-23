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

  A CD can also come from an image that keeps its sectors as the disc has
  them, 2352 bytes each, as a CUE sheet's BIN does: with `:tracks`, audio
  tracks and data tracks of mode 1 or 2 (the kernel's `tracks` attribute,
  another of Kuroneko's patches).

  The target computer learns of a new medium when it next looks at the
  drive. A computer that has locked the medium, such as macOS or Linux with
  the disc mounted, is first asked to eject it, as by the drive's eject
  button; one that does not is then cut off from it: the gadget leaves the
  USB bus and comes back, so that the computer sees the drive anew (see
  `:replug`). It does the same when a drive turns from optical to removable
  disk or back, which the computer only reads when the drive appears.

  A storage function is one USB mass storage device with one or more
  logical units (LUNs), as the kernel calls them, each a drive the target
  computer sees: `{:storage, luns: 3}` in `Kuroneko.Gadget` makes three.

  The functions take a `:gadget` option, `Kuroneko.Gadget.default_gadget/0`
  by default, `:storage`, the storage function's name (`"disk"`, the one
  `:storage` makes, by default), and `:lun`, the logical unit in it: 0, the
  first, by default.
  """

  require Logger

  @typedoc "The image in the drive and how the target computer sees it."
  @type medium() :: %{
          image: Path.t(),
          cdrom: boolean(),
          disc: disc() | nil,
          read_only: boolean(),
          tracks: [track()] | nil
        }

  @typedoc "The disc in the optical drive."
  @type disc() :: :cd | :dvd | :bd

  @typedoc """
  A track of a CD: its number, 1 to 99, in order; `:mode`, `:audio`,
  `:mode1` or `:mode2`; the `:size` of a sector in the image, 2352 bytes,
  or 2048 for mode 1 and 2336 for mode 2 without what comes before the data;
  the `:offset` in the image of its first sector; the sectors of its
  `:pregap` (index 0), none by default; its `:flags`, from
  `:copy_permitted`, `:pre_emphasis` and `:four_channel`.
  """
  @type track() :: %{
          required(:number) => 1..99,
          required(:mode) => :audio | :mode1 | :mode2,
          required(:size) => 2048 | 2336 | 2352,
          required(:offset) => non_neg_integer(),
          optional(:pregap) => non_neg_integer(),
          optional(:flags) => [:copy_permitted | :pre_emphasis | :four_channel]
        }

  @type insert_option() ::
          {:cdrom, boolean()}
          | {:disc, disc()}
          | {:tracks, [track()]}
          | {:read_only, boolean()}
          | {:replug, :auto | boolean()}
          | {:gadget, Path.t()}
          | {:storage, String.t()}
          | {:lun, non_neg_integer()}

  @doc """
  Puts an image in the drive, in place of the one there.

  ## Options

    * `:cdrom` - an optical drive instead of a removable disk; by default for
      images ending in `.iso`
    * `:disc` - the disc in the optical drive, `:cd`, `:dvd` or `:bd`; `:dvd`
      by default, as desktop systems mount ISO images. Without the kernel's
      `profile` attribute only `:cd` goes, and is the default
    * `:tracks` - the tracks of a CD whose image keeps its sectors as the
      disc has them (see `t:track/0`); with them the disc is a CD
    * `:read_only` - the target computer cannot write; by default for optical
      drives
    * `:replug` - whether the gadget leaves the USB bus and comes back after,
      for the target computer to see the drive anew: `:auto`, the default,
      when the drive changes between optical and removable or a medium the
      computer had locked was taken out; `true` always; `false` never. All of
      the gadget's devices reconnect
    * `:storage` - the storage function, `"disk"` by default
    * `:lun` - its logical unit, 0 by default

      Kuroneko.Gadget.Storage.insert("/data/images/tools.iso", storage: "boot", lun: 1)

      Kuroneko.Gadget.Storage.insert("/data/images/album.bin",
        tracks: [
          %{number: 1, mode: :audio, size: 2352, offset: 0},
          %{number: 2, mode: :audio, size: 2352, offset: 41_395_200, pregap: 150}
        ]
      )
  """
  @spec insert(Path.t(), [insert_option()]) :: :ok | {:error, term()}
  def insert(image, opts \\ []) do
    image = Path.expand(image)
    tracks = Keyword.get(opts, :tracks)
    cdrom = Keyword.get_lazy(opts, :cdrom, fn -> tracks != nil or iso?(image) end)
    disc = Keyword.get(opts, :disc, if(tracks, do: :cd))
    read_only = Keyword.get(opts, :read_only, cdrom)
    lun = lun(opts)

    with :ok <- check_lun(lun),
         :ok <- check_image(image),
         {:ok, table} <- tracks_table(tracks, cdrom, disc),
         {:ok, was_cdrom} <- read(lun, "cdrom"),
         {:ok, removal} <- take_out(lun, false, opts),
         :ok <- write(lun, "cdrom", flag(cdrom)),
         :ok <- write_disc(lun, cdrom, disc),
         :ok <- write_tracks(lun, table),
         :ok <- write(lun, "ro", flag(read_only)),
         :ok <- write(lun, "file", image) do
      replug(opts, removal == :forced or was_cdrom != flag(cdrom))
    end
  end

  @doc """
  The number of logical units the storage function has (`:storage`, the
  default one without it), 0 without the function.
  """
  @spec luns(keyword()) :: non_neg_integer()
  def luns(opts \\ []) do
    dir = Kuroneko.Gadget.function_dir(:storage, Keyword.put(opts, :name, opts[:storage]))

    case File.ls(dir) do
      {:ok, names} -> Enum.count(names, &String.starts_with?(&1, "lun."))
      {:error, _reason} -> 0
    end
  end

  @doc """
  The image in each drive of the storage function, `nil` for an empty one,
  in the order of the logical units.
  """
  @spec media(keyword()) :: [medium() | nil]
  def media(opts \\ []) do
    for lun <- 0..(luns(opts) - 1)//1 do
      case medium(Keyword.put(opts, :lun, lun)) do
        {:ok, medium} -> medium
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Takes the image out of the drive, even when the target computer holds it:
  an optical drive first asks the computer to eject it and gives it `:wait`
  milliseconds, 3000 by default. Takes `:replug` as `insert/2` does.
  """
  @spec eject(keyword()) :: :ok | {:error, term()}
  def eject(opts \\ []) do
    lun = lun(opts)

    with :ok <- check_lun(lun),
         {:ok, removal} <- take_out(lun, true, opts),
         do: replug(opts, removal == :forced)
  end

  @doc """
  The image in the drive, `nil` when there is none.
  """
  @spec medium(keyword()) :: {:ok, medium() | nil} | {:error, term()}
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
             read_only: read_only == "1",
             tracks: tracks(lun)
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

  # Out the medium goes: as asked when the computer has not locked it (SCSI
  # "prevent removal", which an empty file name meets with EBUSY); else,
  # when asked to wait, the computer is asked to eject it, as by an optical
  # drive's button; else, or when it does not, forced_eject.
  defp take_out(lun, wait, opts) do
    case read(lun, "file") do
      {:ok, ""} ->
        {:ok, :none}

      {:ok, _image} ->
        case write(lun, "file", "") do
          :ok -> {:ok, :ejected}
          {:error, :ebusy} -> ask_or_force(lun, wait, opts)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ask_or_force(lun, wait, opts) do
    asked = wait and write(lun, "eject_request", "1") == :ok

    if asked and ejected_within?(lun, Keyword.get(opts, :wait, 3000)) do
      {:ok, :ejected}
    else
      with :ok <- write(lun, "forced_eject", "1"), do: {:ok, :forced}
    end
  end

  defp ejected_within?(lun, ms) do
    cond do
      read(lun, "file") == {:ok, ""} ->
        true

      ms <= 0 ->
        false

      true ->
        Process.sleep(min(ms, 100))
        ejected_within?(lun, ms - 100)
    end
  end

  # The medium is in or out by then: a computer that does not see it anew
  # sees it at its next look at the drive.
  defp replug(opts, needed) do
    with mode when mode == true or (mode == :auto and needed) <-
           Keyword.get(opts, :replug, :auto),
         {:error, reason} <- Kuroneko.Gadget.replug(opts) do
      Logger.warning(
        "kuroneko_gadget: the target does not see the drive anew: #{inspect(reason)}"
      )
    end

    :ok
  end

  @modes %{audio: 0, mode1: 1, mode2: 2}
  @sizes %{audio: [2352], mode1: [2048, 2352], mode2: [2336, 2352]}
  @flags %{copy_permitted: 0x2, pre_emphasis: 0x1, four_channel: 0x8}

  # The kernel's table, a line a track: number, mode, the control bits of
  # its Q subchannel, the size of a sector, the pregap, the offset.
  defp tracks_table(nil, _cdrom, _disc), do: {:ok, ""}

  defp tracks_table(tracks, cdrom, disc) when is_list(tracks) and tracks != [] do
    cond do
      not cdrom or disc != :cd ->
        {:error, {:invalid_tracks, :not_a_cd}}

      length(tracks) > 99 ->
        {:error, {:invalid_tracks, :too_many}}

      bad = tracks |> Enum.with_index() |> Enum.find(&(not track?(&1, tracks))) ->
        {:error, {:invalid_tracks, elem(bad, 0)[:number] || elem(bad, 1) + 1}}

      true ->
        {:ok, Enum.map_join(tracks, &track_line/1)}
    end
  end

  defp tracks_table(_tracks, _cdrom, _disc), do: {:error, {:invalid_tracks, :none}}

  defp track?({track, i}, tracks),
    do: track_fields?(track) and follows?(track, if(i > 0, do: Enum.at(tracks, i - 1)))

  defp track_fields?(%{number: n, mode: mode, size: size, offset: offset} = track)
       when is_map_key(@modes, mode) and is_integer(n) and n in 1..99 and is_integer(offset) and
              offset >= 0 do
    pregap = Map.get(track, :pregap, 0)
    flags = Map.get(track, :flags, [])

    size in @sizes[mode] and is_integer(pregap) and pregap >= 0 and is_list(flags) and
      Enum.all?(flags, &is_map_key(@flags, &1))
  end

  defp track_fields?(_track), do: false

  # Numbered one after the other, each further into the image.
  defp follows?(_track, nil), do: true

  defp follows?(track, previous),
    do: track.number == previous.number + 1 and track.offset > previous.offset

  defp track_line(track) do
    flags = Enum.reduce(Map.get(track, :flags, []), 0, &Bitwise.bor(@flags[&1], &2))
    control = if track.mode == :audio, do: flags, else: Bitwise.bor(0x4, Bitwise.band(flags, 0x2))

    "#{track.number} #{@modes[track.mode]} #{control} #{track.size} " <>
      "#{Map.get(track, :pregap, 0)} #{track.offset}\n"
  end

  defp write_tracks(lun, table) do
    cond do
      File.exists?(Path.join(lun, "tracks")) -> write(lun, "tracks", table)
      table == "" -> :ok
      true -> {:error, :tracks_unsupported}
    end
  end

  defp tracks(lun) do
    case read(lun, "tracks") do
      {:ok, table} when table != "" ->
        table |> String.split("\n", trim: true) |> Enum.map(&parse_track/1)

      _none ->
        nil
    end
  end

  defp parse_track(line) do
    [number, mode, control, size, pregap, offset] =
      line |> String.split() |> Enum.map(&String.to_integer/1)

    mode = Enum.find_value(@modes, fn {name, value} -> value == mode && name end)
    flags = for {flag, bit} <- @flags, Bitwise.band(control, bit) != 0, do: flag
    flags = if mode == :audio, do: flags, else: flags -- [:pre_emphasis, :four_channel]

    %{
      number: number,
      mode: mode,
      size: size,
      pregap: pregap,
      offset: offset,
      flags: Enum.sort(flags)
    }
  end

  # The LUN's directory in the storage function: `:storage` names the
  # function, `:lun` the logical unit in it, the first by default.
  defp lun(opts) do
    dir = Kuroneko.Gadget.function_dir(:storage, Keyword.put(opts, :name, opts[:storage]))
    Path.join(dir, "lun.#{Keyword.get(opts, :lun, 0)}")
  end

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

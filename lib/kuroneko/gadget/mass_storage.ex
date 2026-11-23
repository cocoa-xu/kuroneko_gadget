defmodule Kuroneko.Gadget.MassStorage do
  @moduledoc """
  The kernel's mass storage function: drives the target computer sees,
  each holding an image file.

      Kuroneko.Gadget.MassStorage.insert("/data/images/debian.iso")
      Kuroneko.Gadget.MassStorage.medium()
      #=> {:ok, %{image: "/data/images/debian.iso", as: :dvd, read_only: true, tracks: nil}}
      Kuroneko.Gadget.MassStorage.eject()

  An instance is one USB mass storage device whose logical units (LUNs)
  are its drives. The `:storage` of `Kuroneko.Gadget` is an instance named
  `"disk"`, and `{:storage, luns: 3}` has three drives.

  A drive holds its image as a removable disk or as a disc in an optical
  drive: a CD, a DVD or a BD. A CD is also addressed in minutes, seconds
  and frames, which end at 255:59:74, about 2.3 GB. A CD can have audio and
  data tracks, from an image that keeps its sectors as the disc has them,
  as a CUE sheet's BIN does. DVDs, BDs and tracks need Kuroneko's kernel
  patches, the LUN's `profile` and `tracks` attributes.

  The target learns of a new medium when it next looks at the drive. A
  target that has locked the medium, such as macOS or Linux with the disc
  mounted, is first asked to eject it, as by an optical drive's button, and
  is cut off from it when it does not: the gadget leaves the USB bus and
  comes back, and the target sees the drive anew. The same happens when a
  drive turns from optical to removable or back, which a target reads only
  when the drive appears.

  ## Options

    * `:luns` - the drives, 1 to 16; 1 by default
    * `:inquiry` - the drives' SCSI vendor, product and revision as
      `{vendor, product, revision}`, of up to 8, 16 and 4 ASCII characters;
      the kernel's by default

  The drive functions take `:name`, the instance, `"disk"` by default;
  `:lun`, the drive, 0 by default; `:gadget`; and `:server`, the
  `Kuroneko.Gadget` process that replugs the gadget, `Kuroneko.Gadget` by
  default.
  """

  @behaviour Kuroneko.Gadget.Function

  require Logger

  alias Kuroneko.Gadget.Configfs

  @typedoc "How a drive holds its image: as a removable disk, or as a disc."
  @type as() :: :disk | :cd | :dvd | :bd

  @typedoc "The image in a drive and how the target sees it."
  @type medium() :: %{
          image: Path.t(),
          as: as(),
          read_only: boolean(),
          tracks: [track()] | nil
        }

  @typedoc """
  A track of a CD: its number, 1 to 99, in order; `:mode`, `:audio`,
  `:mode1` or `:mode2`; the `:size` of a sector in the image, 2352 bytes,
  or 2048 for mode 1 and 2336 for mode 2 without what comes before the
  data; the `:offset` in the image of its first sector; the sectors of its
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

  @type drive_option() ::
          {:name, String.t()}
          | {:lun, non_neg_integer()}
          | {:gadget, Path.t()}
          | {:server, GenServer.server()}

  @type insert_option() ::
          {:as, as()}
          | {:tracks, [track()]}
          | {:read_only, boolean()}
          | {:replug, :auto | boolean()}
          | drive_option()

  @type eject_option() ::
          {:wait, non_neg_integer()} | {:replug, :auto | boolean()} | drive_option()

  @discs [:cd, :dvd, :bd]
  @drive_options [:name, :lun, :gadget, :server]
  @modes %{audio: 0, mode1: 1, mode2: 2}
  @sizes %{audio: [2352], mode1: [2048, 2352], mode2: [2336, 2352]}
  @flags %{copy_permitted: 0x2, pre_emphasis: 0x1, four_channel: 0x8}

  @impl Kuroneko.Gadget.Function
  def type, do: "mass_storage"

  @impl Kuroneko.Gadget.Function
  def default_name, do: "disk"

  @impl Kuroneko.Gadget.Function
  def settings(opts) do
    with {:ok, opts} <- validate(opts, luns: 1, inquiry: nil),
         {:ok, luns} <- check_luns(opts[:luns]),
         {:ok, inquiry} <- check_inquiry(opts[:inquiry]) do
      {:ok, %{luns: luns, inquiry: inquiry}}
    end
  end

  @impl Kuroneko.Gadget.Function
  def endpoints(_settings), do: %{in: 1, out: 1}

  @impl Kuroneko.Gadget.Function
  def setup(dir, %{luns: luns, inquiry: inquiry}), do: add_luns(dir, 0..(luns - 1), inquiry)

  @impl Kuroneko.Gadget.Function
  def read(dir) do
    case count_luns(dir) do
      0 -> :error
      luns -> {:ok, %{luns: luns, inquiry: read_inquiry(Path.join(dir, "lun.0"))}}
    end
  end

  @impl Kuroneko.Gadget.Function
  def update(dir, from, to) do
    with :ok <- remove_luns(dir, (from.luns - 1)..to.luns//-1),
         :ok <- add_luns(dir, from.luns..(to.luns - 1)//1, to.inquiry) do
      if from.inquiry == to.inquiry,
        do: :ok,
        else:
          each_lun(dir, 0..(to.luns - 1), &Configfs.write_all(&1, inquiry_attribute(to.inquiry)))
    end
  end

  @impl Kuroneko.Gadget.Function
  def teardown(dir, _settings), do: remove_luns(dir, (count_luns(dir) - 1)..1//-1)

  @doc """
  Puts an image in a drive, in place of the one there.

  ## Options

    * `:as` - `:disk`, a removable disk, or a disc: `:cd`, `:dvd` or `:bd`.
      By default an image holding ISO 9660 or UDF is a DVD, or a CD where
      the kernel has no `profile` attribute, and any other image a disk.
    * `:tracks` - the tracks of a CD whose image keeps its sectors as the
      disc has them (see `t:track/0`), which makes the image a CD
    * `:read_only` - whether the target cannot write; by default for discs
    * `:replug` - whether the gadget leaves the USB bus and comes back
      after, for the target to see the drive anew: `:auto`, the default,
      when the drive changes between optical and removable or a medium the
      target had locked was taken out; `true`; `false`. All of the gadget's
      devices reconnect.
    * the drive options of the module documentation

      Kuroneko.Gadget.MassStorage.insert("/data/images/tools.iso", name: "boot", lun: 1)

      Kuroneko.Gadget.MassStorage.insert("/data/images/album.bin",
        tracks: [
          %{number: 1, mode: :audio, size: 2352, offset: 0},
          %{number: 2, mode: :audio, size: 2352, offset: 41_395_200, pregap: 150}
        ]
      )
  """
  @spec insert(Path.t(), [insert_option()]) :: :ok | {:error, term()}
  def insert(image, opts \\ []) do
    opts = Keyword.validate!(opts, [:as, :tracks, :read_only, replug: :auto] ++ @drive_options)
    check_option!(opts, :as, [nil, :disk | @discs])
    check_option!(opts, :read_only, [nil, true, false])
    check_option!(opts, :replug, [:auto, true, false])
    image = Path.expand(image)

    with {:ok, lun} <- lun_dir(opts),
         :ok <- check_image(image),
         {:ok, as} <- choose_as(lun, image, opts[:as], opts[:tracks]),
         {:ok, table} <- tracks_table(opts[:tracks], as),
         {:ok, was} <- optical?(lun),
         {:ok, removal} <- take_out(lun, :force),
         :ok <- write_as(lun, as),
         :ok <- write_tracks(lun, table),
         :ok <- write_flag(lun, "ro", read_only(opts[:read_only], as)),
         :ok <- Configfs.write(Path.join(lun, "file"), image) do
      replug(opts, removal == :forced or was != (as != :disk))
    end
  end

  @doc """
  Takes the image out of a drive, even when the target holds it: an
  optical drive first asks the target to eject it and waits `:wait`
  milliseconds, 3000 by default. Takes `:replug` and the drive options as
  `insert/2` does.
  """
  @spec eject([eject_option()]) :: :ok | {:error, term()}
  def eject(opts \\ []) do
    opts = Keyword.validate!(opts, [wait: 3000, replug: :auto] ++ @drive_options)
    check_option!(opts, :replug, [:auto, true, false])

    with {:ok, lun} <- lun_dir(opts),
         {:ok, removal} <- take_out(lun, {:ask, opts[:wait]}),
         do: replug(opts, removal == :forced)
  end

  @doc "The image in a drive, `nil` when there is none. Takes the drive options."
  @spec medium([drive_option()]) :: {:ok, medium() | nil} | {:error, term()}
  def medium(opts \\ []) do
    opts = Keyword.validate!(opts, @drive_options)

    with {:ok, lun} <- lun_dir(opts),
         {:ok, image} <- Configfs.read_text(Path.join(lun, "file")) do
      if image == "", do: {:ok, nil}, else: read_medium(lun, image)
    end
  end

  @doc """
  The image in each drive of an instance, `nil` for an empty one, in the
  order of the drives. Takes `:name` and `:gadget`.
  """
  @spec media([drive_option()]) :: [medium() | nil]
  def media(opts \\ []) do
    opts = Keyword.validate!(opts, @drive_options)

    for lun <- 0..(lun_count(opts) - 1)//1 do
      case medium(Keyword.put(opts, :lun, lun)) do
        {:ok, medium} -> medium
        {:error, _reason} -> nil
      end
    end
  end

  @doc "The drives of an instance, 0 without it. Takes `:name` and `:gadget`."
  @spec lun_count([drive_option()]) :: non_neg_integer()
  def lun_count(opts \\ []) do
    opts = Keyword.validate!(opts, @drive_options)
    count_luns(Kuroneko.Gadget.function_dir(__MODULE__, Keyword.take(opts, [:name, :gadget])))
  end

  defp validate(opts, defaults) do
    case Keyword.validate(opts, defaults) do
      {:ok, opts} -> {:ok, opts}
      {:error, unknown} -> {:error, {:unknown_options, __MODULE__, unknown}}
    end
  end

  defp check_luns(luns) when luns in 1..16, do: {:ok, luns}
  defp check_luns(luns), do: {:error, {:invalid_luns, luns}}

  defp check_inquiry(nil), do: {:ok, nil}

  defp check_inquiry({vendor, product, revision} = inquiry) do
    fields = [{vendor, 8}, {product, 16}, {revision, 4}]

    if Enum.all?(fields, fn {text, size} -> inquiry_field?(text, size) end),
      do:
        {:ok,
         {String.trim_trailing(vendor), String.trim_trailing(product),
          String.trim_trailing(revision)}},
      else: {:error, {:invalid_inquiry, inquiry}}
  end

  defp check_inquiry(inquiry), do: {:error, {:invalid_inquiry, inquiry}}

  defp inquiry_field?(text, size),
    do: is_binary(text) and byte_size(text) <= size and String.match?(text, ~r/^[\x20-\x7E]*$/)

  # configfs makes lun.0 with the function, the others by mkdir.
  defp add_luns(dir, numbers, inquiry) do
    attributes =
      [{"removable", "1"}, {"cdrom", "0"}, {"ro", "0"}, {"nofua", "0"}] ++
        inquiry_attribute(inquiry)

    each_lun(dir, numbers, fn lun ->
      with :ok <- Configfs.mkdir(lun), do: Configfs.write_all(lun, attributes)
    end)
  end

  defp remove_luns(dir, numbers), do: each_lun(dir, numbers, &Configfs.rmdir/1)

  defp each_lun(dir, numbers, fun) do
    Enum.reduce_while(numbers, :ok, fn number, :ok ->
      case fun.(Path.join(dir, "lun.#{number}")) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp count_luns(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.count(names, &String.starts_with?(&1, "lun."))
      {:error, _reason} -> 0
    end
  end

  defp inquiry_attribute(nil), do: []

  defp inquiry_attribute({vendor, product, revision}) do
    field = fn text, size -> String.pad_trailing(text, size) end
    [{"inquiry_string", field.(vendor, 8) <> field.(product, 16) <> field.(revision, 4)}]
  end

  defp read_inquiry(lun) do
    case File.read(Path.join(lun, "inquiry_string")) do
      {:ok, <<vendor::binary-8, product::binary-16, revision::binary-4, _newline::binary>>} ->
        {String.trim_trailing(vendor), String.trim_trailing(product),
         String.trim_trailing(revision)}

      _empty_or_missing ->
        nil
    end
  end

  defp check_option!(opts, key, allowed) do
    value = opts[key]

    if value not in allowed,
      do:
        raise(
          ArgumentError,
          "expected #{inspect(key)} to be one of #{inspect(allowed)}, got: #{inspect(value)}"
        )
  end

  defp lun_dir(opts) do
    function = Kuroneko.Gadget.function_dir(__MODULE__, Keyword.take(opts, [:name, :gadget]))
    lun = Path.join(function, "lun.#{Keyword.get(opts, :lun, 0)}")
    if File.dir?(lun), do: {:ok, lun}, else: {:error, :no_storage}
  end

  defp check_image(image) do
    if File.regular?(image), do: :ok, else: {:error, {:no_image, image}}
  end

  defp choose_as(lun, image, nil, nil),
    do: {:ok, if(disc_image?(image), do: default_disc(lun), else: :disk)}

  defp choose_as(_lun, _image, nil, _tracks), do: {:ok, :cd}
  defp choose_as(_lun, _image, as, tracks) when tracks == nil or as == :cd, do: {:ok, as}
  defp choose_as(_lun, _image, as, _tracks), do: {:error, {:invalid_tracks, {:as, as}}}

  # ISO 9660 and UDF both start their descriptors at sector 16.
  defp disc_image?(image) do
    case File.open(image, [:read, :binary, :raw]) do
      {:ok, file} ->
        header = :file.pread(file, 32_769, 5)
        :ok = File.close(file)
        header in [{:ok, "CD001"}, {:ok, "BEA01"}]

      {:error, _reason} ->
        false
    end
  end

  defp default_disc(lun), do: if(File.exists?(Path.join(lun, "profile")), do: :dvd, else: :cd)

  defp optical?(lun) do
    with {:ok, cdrom} <- Configfs.read_text(Path.join(lun, "cdrom")), do: {:ok, cdrom == "1"}
  end

  defp write_as(lun, :disk), do: Configfs.write(Path.join(lun, "cdrom"), "0")

  defp write_as(lun, disc) do
    with :ok <- Configfs.write(Path.join(lun, "cdrom"), "1") do
      cond do
        File.exists?(Path.join(lun, "profile")) ->
          Configfs.write(Path.join(lun, "profile"), Atom.to_string(disc))

        disc == :cd ->
          :ok

        true ->
          {:error, :disc_unsupported}
      end
    end
  end

  defp read_only(nil, as), do: as != :disk
  defp read_only(read_only, _as), do: read_only

  defp write_flag(lun, attribute, on),
    do: Configfs.write(Path.join(lun, attribute), if(on, do: "1", else: "0"))

  defp read_medium(lun, image) do
    with {:ok, optical} <- optical?(lun),
         {:ok, read_only} <- Configfs.read_text(Path.join(lun, "ro")) do
      {:ok,
       %{
         image: image,
         as: if(optical, do: disc(lun), else: :disk),
         read_only: read_only == "1",
         tracks: tracks(lun)
       }}
    end
  end

  defp disc(lun) do
    case Configfs.read_text(Path.join(lun, "profile")) do
      {:ok, "dvd"} -> :dvd
      {:ok, "bd"} -> :bd
      _cd_or_no_profile -> :cd
    end
  end

  # An empty file name takes the medium out, unless the target has locked
  # it ("prevent medium removal"): EBUSY. A newline, since writing nothing
  # does not reach the kernel.
  defp take_out(lun, how) do
    case Configfs.read_text(Path.join(lun, "file")) do
      {:ok, ""} -> {:ok, :none}
      {:ok, _image} -> empty(lun, how)
      error -> error
    end
  end

  defp empty(lun, how) do
    case Configfs.write(Path.join(lun, "file"), "\n") do
      :ok -> {:ok, :ejected}
      {:error, {:configfs, _path, :ebusy}} -> ask_or_force(lun, how)
      error -> error
    end
  end

  defp ask_or_force(lun, {:ask, wait}) do
    if Configfs.write(Path.join(lun, "eject_request"), "1") == :ok and ejected_within?(lun, wait),
      do: {:ok, :ejected},
      else: ask_or_force(lun, :force)
  end

  defp ask_or_force(lun, :force) do
    with :ok <- Configfs.write(Path.join(lun, "forced_eject"), "1"), do: {:ok, :forced}
  end

  # The kernel tells no one when the target ejects: look.
  defp ejected_within?(lun, ms) do
    cond do
      Configfs.read_text(Path.join(lun, "file")) == {:ok, ""} ->
        true

      ms <= 0 ->
        false

      true ->
        Process.sleep(min(ms, 100))
        ejected_within?(lun, ms - 100)
    end
  end

  defp replug(opts, needed) do
    if opts[:replug] == true or (opts[:replug] == :auto and needed) do
      with {:error, reason} <- Kuroneko.Gadget.replug(Keyword.get(opts, :server, Kuroneko.Gadget)) do
        Logger.warning(
          "kuroneko_gadget: the target does not see the drive anew: #{inspect(reason)}"
        )
      end
    end

    :ok
  end

  defp tracks_table(nil, _as), do: {:ok, ""}

  defp tracks_table(tracks, :cd) when is_list(tracks) and tracks != [] and length(tracks) <= 99 do
    case Enum.find(Enum.zip([nil | tracks], tracks), fn {previous, track} ->
           not track?(track, previous)
         end) do
      nil -> {:ok, Enum.map_join(tracks, &track_line/1)}
      {_previous, track} -> {:error, {:invalid_tracks, track}}
    end
  end

  defp tracks_table(tracks, _as), do: {:error, {:invalid_tracks, tracks}}

  defp track?(track, previous), do: track_fields?(track) and follows?(track, previous)

  defp track_fields?(%{number: number, mode: mode, size: size, offset: offset} = track)
       when number in 1..99 and is_map_key(@modes, mode) and is_integer(offset) and offset >= 0 do
    pregap = Map.get(track, :pregap, 0)
    flags = Map.get(track, :flags, [])

    size in @sizes[mode] and is_integer(pregap) and pregap >= 0 and is_list(flags) and
      Enum.all?(flags, &is_map_key(@flags, &1))
  end

  defp track_fields?(_track), do: false

  defp follows?(_track, nil), do: true

  defp follows?(track, previous),
    do: track.number == previous.number + 1 and track.offset > previous.offset

  # A line a track, the kernel's: number, mode, the control bits of its Q
  # subchannel, the size of a sector, the pregap, the offset.
  defp track_line(track) do
    flags = Enum.reduce(Map.get(track, :flags, []), 0, &Bitwise.bor(@flags[&1], &2))
    control = if track.mode == :audio, do: flags, else: Bitwise.bor(0x4, Bitwise.band(flags, 0x2))

    "#{track.number} #{@modes[track.mode]} #{control} #{track.size} " <>
      "#{Map.get(track, :pregap, 0)} #{track.offset}\n"
  end

  # A newline clears the table, since writing nothing does not reach the
  # kernel.
  defp write_tracks(lun, table) do
    cond do
      File.exists?(Path.join(lun, "tracks")) ->
        Configfs.write(Path.join(lun, "tracks"), if(table == "", do: "\n", else: table))

      table == "" ->
        :ok

      true ->
        {:error, :tracks_unsupported}
    end
  end

  defp tracks(lun) do
    case Configfs.read_text(Path.join(lun, "tracks")) do
      {:ok, table} when table != "" ->
        table |> String.split("\n", trim: true) |> Enum.map(&parse_track/1)

      _none ->
        nil
    end
  end

  defp parse_track(line) do
    [number, mode, control, size, pregap, offset] =
      line |> String.split() |> Enum.map(&String.to_integer/1)

    {mode, _value} = Enum.find(@modes, fn {_name, value} -> value == mode end)
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
end

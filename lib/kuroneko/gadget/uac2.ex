defmodule Kuroneko.Gadget.UAC2 do
  @moduledoc """
  The kernel's USB Audio Class 2 function: a sound card with a microphone
  the target records from, a speaker it plays to, or both. Linux shows it
  on the device as the ALSA card `UAC2Gadget`.

  The `:microphone` and `:speaker` of `Kuroneko.Gadget` are the two
  directions of an instance named `"audio"`. The target's volume and mute
  controls act on the samples.

  ## Options

    * `:microphone`, `:speaker` - each direction's format, without which the
      direction is left out:
      * `:channels` - 1 (mono) to 8, 2 (stereo) by default
      * `:rates` - the sample rates the target chooses from, up to 10,
        `[48_000]` by default. The target starts with the first.
      * `:sample_bits` - 16, 24 or 32, 16 by default
    * `:max_packet` - the largest packets the device controller takes for
      each direction, in bytes: `%{microphone: 1024, speaker: 1024}` by
      default, the most high speed carries. A format whose packets do not
      fit is refused.
    * `:names` - what the target calls the card and its directions,
      `[function: ..., microphone: ..., speaker: ...]`; the kernel's names
      by default
  """

  @behaviour Kuroneko.Gadget.Function

  import Bitwise

  alias Kuroneko.Gadget.Configfs

  @typedoc "A direction's format."
  @type format() :: %{
          channels: 1..8,
          rates: [pos_integer(), ...],
          sample_bits: 16 | 24 | 32,
          interval: 1..4
        }

  @prefix %{microphone: "p_", speaker: "c_"}
  # Front left and right, center, LFE, back, side.
  @channel_masks %{
    1 => 0x1,
    2 => 0x3,
    3 => 0x7,
    4 => 0x33,
    5 => 0x37,
    6 => 0x3F,
    7 => 0x13F,
    8 => 0x63F
  }
  @kernel_names %{
    "function_name" => "Source/Sink",
    "p_alt0_name" => "Playback Inactive",
    "p_alt1_name" => "Playback Active",
    "c_alt0_name" => "Capture Inactive",
    "c_alt1_name" => "Capture Active"
  }

  @impl Kuroneko.Gadget.Function
  def type, do: "uac2"

  @impl Kuroneko.Gadget.Function
  def default_name, do: "audio"

  @impl Kuroneko.Gadget.Function
  def settings(opts) do
    defaults = [microphone: nil, speaker: nil, max_packet: %{}, names: []]

    with {:ok, opts} <- validate(opts, defaults),
         max_packet = Map.merge(%{microphone: 1024, speaker: 1024}, Map.new(opts[:max_packet])),
         {:ok, microphone} <- format(:microphone, opts[:microphone], max_packet),
         {:ok, speaker} <- format(:speaker, opts[:speaker], max_packet),
         {:ok, names} <- names(opts[:names]) do
      if microphone || speaker,
        do: {:ok, %{microphone: microphone, speaker: speaker, names: names}},
        else: {:error, :no_direction}
    end
  end

  @impl Kuroneko.Gadget.Function
  def endpoints(%{microphone: microphone, speaker: speaker}),
    do: %{in: if(microphone, do: 1, else: 0), out: if(speaker, do: 1, else: 0)}

  # No feedback endpoint: the speaker follows the target's clock. No
  # interrupt endpoint where the kernel allows: the controls do without, and
  # the other functions need the endpoints.
  @impl Kuroneko.Gadget.Function
  def setup(dir, settings) do
    attributes =
      direction_attributes(:microphone, settings.microphone) ++
        direction_attributes(:speaker, settings.speaker) ++ [{"c_sync", "adaptive"}]

    with :ok <- Configfs.write_all(dir, attributes),
         do: Configfs.write_existing(dir, [{"int_ep_present", "0"} | Map.to_list(settings.names)])
  end

  @impl Kuroneko.Gadget.Function
  def read(dir) do
    microphone = read_direction(dir, :microphone)
    speaker = read_direction(dir, :speaker)

    if microphone || speaker,
      do: {:ok, %{microphone: microphone, speaker: speaker, names: read_names(dir)}},
      else: :error
  end

  defp validate(opts, defaults) do
    case Keyword.validate(opts, defaults) do
      {:ok, opts} -> {:ok, opts}
      {:error, unknown} -> {:error, {:unknown_options, __MODULE__, unknown}}
    end
  end

  defp format(_direction, nil, _max_packet), do: {:ok, nil}

  defp format(direction, opts, max_packet) when is_list(opts) do
    case Keyword.validate(opts, channels: 2, rates: [48_000], sample_bits: 16) do
      {:ok, opts} -> check_format(direction, Map.new(opts), max_packet[direction])
      {:error, unknown} -> {:error, {:unknown_options, direction, unknown}}
    end
  end

  defp format(direction, opts, _max_packet), do: {:error, {:invalid_format, direction, opts}}

  defp check_format(direction, format, max_packet) do
    cond do
      not is_map_key(@channel_masks, format.channels) ->
        {:error, {:invalid_channels, direction, format.channels}}

      not rates?(format.rates) ->
        {:error, {:invalid_rates, direction, format.rates}}

      format.sample_bits not in [16, 24, 32] ->
        {:error, {:invalid_sample_bits, direction, format.sample_bits}}

      true ->
        format = %{format | rates: Enum.uniq(format.rates)}

        case interval(direction, format, max_packet) do
          nil -> {:error, {:too_much_bandwidth, direction, format}}
          interval -> {:ok, Map.put(format, :interval, interval)}
        end
    end
  end

  defp rates?(rates) do
    is_list(rates) and length(rates) in 1..10 and
      Enum.all?(rates, &(is_integer(&1) and &1 in 8_000..384_000))
  end

  # High speed sends a packet each 125 µs × 2^(interval - 1): the longest
  # interval whose packets the controller takes.
  defp interval(direction, format, max_packet),
    do: Enum.find(4..1//-1, &(packet_size(direction, format, &1) <= max_packet))

  # As f_uac2 reckons it: the microphone may run 0.5 % fast, and the
  # speaker's packets have room for a frame more.
  defp packet_size(direction, format, interval) do
    frame = format.channels * div(format.sample_bits, 8)
    per_second = div(8000, 1 <<< (interval - 1))
    rate = Enum.max(format.rates)

    case direction do
      :microphone -> frame * ceil_div(div(rate * 1005, 1000), per_second)
      :speaker -> frame * (ceil_div(rate, per_second) + 1)
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp names(names) when is_list(names) do
    case Keyword.validate(names, [:function, :microphone, :speaker]) do
      {:ok, names} -> name_attributes(names)
      {:error, unknown} -> {:error, {:unknown_options, :names, unknown}}
    end
  end

  defp names(names), do: {:error, {:invalid_names, names}}

  defp name_attributes(names) do
    if Enum.all?(names, fn {_key, name} -> is_binary(name) end),
      do: {:ok, Map.merge(@kernel_names, Map.new(Enum.flat_map(names, &name_attribute/1)))},
      else: {:error, {:invalid_names, names}}
  end

  defp name_attribute({:function, name}), do: [{"function_name", name}]
  defp name_attribute({:microphone, name}), do: [{"p_alt0_name", name}, {"p_alt1_name", name}]
  defp name_attribute({:speaker, name}), do: [{"c_alt0_name", name}, {"c_alt1_name", name}]

  defp direction_attributes(direction, nil), do: [{@prefix[direction] <> "chmask", "0"}]

  defp direction_attributes(direction, format) do
    prefix = @prefix[direction]

    [
      {prefix <> "chmask", Integer.to_string(@channel_masks[format.channels])},
      {prefix <> "srate", Enum.map_join(format.rates, ",", &Integer.to_string/1)},
      {prefix <> "ssize", Integer.to_string(div(format.sample_bits, 8))},
      {prefix <> "hs_bint", Integer.to_string(format.interval)}
    ]
  end

  defp read_direction(dir, direction) do
    read = fn attribute -> Configfs.read_text(Path.join(dir, @prefix[direction] <> attribute)) end

    with {:ok, mask} <- read.("chmask"),
         mask when mask > 0 <- String.to_integer(mask),
         {:ok, rates} <- read.("srate"),
         {:ok, ssize} <- read.("ssize"),
         {:ok, interval} <- read.("hs_bint") do
      %{
        channels: popcount(mask),
        rates: rates |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1),
        sample_bits: String.to_integer(ssize) * 8,
        interval: String.to_integer(interval)
      }
    else
      _none -> nil
    end
  end

  defp read_names(dir) do
    Map.new(@kernel_names, fn {attribute, kernels} ->
      case Configfs.read_text(Path.join(dir, attribute)) do
        {:ok, name} -> {attribute, name}
        {:error, _missing} -> {attribute, kernels}
      end
    end)
  end

  defp popcount(0), do: 0
  defp popcount(n), do: (n &&& 1) + popcount(n >>> 1)
end

defmodule Kuroneko.Gadget.Kinds do
  @moduledoc false

  alias Kuroneko.Gadget.HID
  alias Kuroneko.Gadget.MassStorage
  alias Kuroneko.Gadget.NCM
  alias Kuroneko.Gadget.UAC2

  @type kind() :: Kuroneko.Gadget.kind()

  @type defaults() :: %{names: keyword(), max_packet: map()}

  @modules %{
    keyboard: HID,
    mouse: HID,
    relative_mouse: HID,
    storage: MassStorage,
    network: NCM,
    microphone: UAC2,
    speaker: UAC2,
    audio: UAC2
  }
  @default_names %{
    keyboard: "keyboard",
    mouse: "mouse",
    relative_mouse: "relative_mouse",
    storage: "disk",
    network: "usb0",
    microphone: "audio",
    speaker: "audio",
    audio: "audio"
  }
  @order [:network, :keyboard, :mouse, :relative_mouse, :storage, :audio]
  @pointer_modes %{absolute: :mouse, stylus: :stylus, touch: :touch}
  @builtin_modes %{mouse: :absolute, stylus: :stylus, touch: :touch}
  @types %{"hid" => HID, "mass_storage" => MassStorage, "ncm" => NCM, "uac2" => UAC2}

  defguard is_kind(kind) when is_map_key(@modules, kind)

  @spec module(kind()) :: module()
  def module(kind), do: Map.fetch!(@modules, kind)

  @spec default_name(kind()) :: String.t()
  def default_name(kind), do: Map.fetch!(@default_names, kind)

  # A microphone and a speaker of a name are one sound card.
  @spec expand([term()], defaults()) :: {:ok, [term()]} | {:error, term()}
  def expand(specs, defaults) do
    with {:ok, expanded} <- map_ok(specs, &expand_spec(&1, defaults)) do
      {cards, others} = Enum.split_with(expanded, &match?({:card, _name, _directions}, &1))
      merge_cards(cards, others, defaults)
    end
  end

  @spec describe(map()) :: map()
  def describe(%{module: HID, name: name, settings: descriptor}) do
    case HID.builtin(descriptor) do
      :keyboard -> %{kind: :keyboard, name: name}
      :relative_mouse -> %{kind: :relative_mouse, name: name}
      nil -> %{kind: HID, name: name, settings: descriptor}
      builtin -> %{kind: :mouse, name: name, mode: Map.fetch!(@builtin_modes, builtin)}
    end
  end

  def describe(%{module: MassStorage, name: name, settings: settings}),
    do: %{kind: :storage, name: name, luns: settings.luns}

  def describe(%{module: NCM, name: name}), do: %{kind: :network, name: name}

  def describe(%{module: UAC2, name: name, settings: settings}) do
    %{
      kind: :audio,
      name: name,
      microphone: settings.microphone && Map.delete(settings.microphone, :interval),
      speaker: settings.speaker && Map.delete(settings.speaker, :interval)
    }
  end

  def describe(%{module: module, name: name, settings: settings}),
    do: %{kind: module, name: name, settings: settings}

  @spec rank(map()) :: non_neg_integer()
  def rank(instance) do
    case Enum.find_index(@order, &(&1 == describe(instance).kind)) do
      nil -> length(@order)
      index -> index
    end
  end

  # A HID function is a built-in kind's by its descriptor or its name.
  @spec recognize(Path.t()) :: [map()]
  def recognize(dir) do
    with [type, name] <- String.split(Path.basename(dir), ".", parts: 2),
         {:ok, module} <- Map.fetch(@types, type),
         {:ok, settings} <- module.read(dir),
         true <- kind_function?(module, name, settings) do
      [%{module: module, name: name, settings: settings}]
    else
      _not_a_kind -> []
    end
  end

  defp kind_function?(HID, name, descriptor),
    do: HID.builtin(descriptor) != nil or name in ["keyboard", "mouse", "relative_mouse"]

  defp kind_function?(_module, _name, _settings), do: true

  defp expand_spec(kind, defaults) when is_kind(kind) and kind != :audio,
    do: expand_spec({kind, []}, defaults)

  defp expand_spec({kind, opts} = spec, defaults) when is_kind(kind) and is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, @default_names[kind])

    cond do
      not Keyword.keyword?(opts) -> {:error, {:invalid_options, spec}}
      not valid_name?(name) -> {:error, {:invalid_name, kind, name}}
      true -> kind_spec(kind, name, opts, defaults)
    end
  end

  defp expand_spec(spec, _defaults), do: {:ok, spec}

  defp kind_spec(kind, name, opts, _defaults) when kind in [:keyboard, :relative_mouse] do
    with :ok <- no_options(kind, opts), do: {:ok, {HID, name: name, descriptor: kind}}
  end

  defp kind_spec(:mouse, name, opts, _defaults) do
    case Keyword.validate(opts, mode: :absolute) do
      {:ok, [mode: mode]} when is_map_key(@pointer_modes, mode) ->
        {:ok, {HID, name: name, descriptor: @pointer_modes[mode]}}

      {:ok, [mode: mode]} ->
        {:error, {:invalid_mode, :mouse, mode}}

      {:error, unknown} ->
        {:error, {:unknown_options, :mouse, unknown}}
    end
  end

  defp kind_spec(:storage, name, opts, defaults) do
    case Keyword.validate(opts, luns: 1) do
      {:ok, [luns: luns]} ->
        {:ok, {MassStorage, name: name, luns: luns, inquiry: defaults.names[:storage]}}

      {:error, unknown} ->
        {:error, {:unknown_options, :storage, unknown}}
    end
  end

  defp kind_spec(:network, name, opts, _defaults) do
    with :ok <- no_options(:network, opts), do: {:ok, {NCM, name: name}}
  end

  defp kind_spec(direction, name, format, _defaults) when direction in [:microphone, :speaker],
    do: {:ok, {:card, name, [{direction, format}]}}

  defp kind_spec(:audio, name, opts, _defaults) do
    case Keyword.validate(opts, [:microphone, :speaker]) do
      {:ok, directions} ->
        {:ok,
         {:card, name,
          for({direction, format} <- directions, format, do: {direction, as_options(format)})}}

      {:error, unknown} ->
        {:error, {:unknown_options, :audio, unknown}}
    end
  end

  defp no_options(_kind, []), do: :ok
  defp no_options(kind, opts), do: {:error, {:unknown_options, kind, Keyword.keys(opts)}}

  defp as_options(format) when is_map(format),
    do: format |> Map.delete(:interval) |> Map.to_list()

  defp as_options(format), do: format

  defp merge_cards(cards, others, defaults) do
    with {:ok, merged} <- Enum.reduce_while(cards, {:ok, %{}}, &add_card/2),
         do: {:ok, others ++ Enum.map(merged, &card_spec(&1, defaults))}
  end

  defp add_card({:card, name, directions}, {:ok, merged}) do
    card = Map.get(merged, name, %{})

    case Enum.find(directions, fn {direction, _format} -> is_map_key(card, direction) end) do
      nil -> {:cont, {:ok, Map.put(merged, name, Map.merge(card, Map.new(directions)))}}
      {direction, _format} -> {:halt, {:error, {:duplicate_function, direction}}}
    end
  end

  defp card_spec({name, directions}, defaults) do
    {UAC2,
     [name: name, max_packet: defaults.max_packet, names: audio_names(defaults.names)] ++
       Map.to_list(directions)}
  end

  defp audio_names(names) do
    for {key, name} <- names, key in [:audio, :microphone, :speaker] do
      {if(key == :audio, do: :function, else: key), name}
    end
  end

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name),
    do: is_binary(name) and byte_size(name) in 1..32 and String.match?(name, ~r/^[A-Za-z0-9_-]+$/)

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end

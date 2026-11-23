defmodule Kuroneko.Gadget.FunctionFS do
  @moduledoc """
  FunctionFS: a USB function whose interfaces and endpoints are a
  program's, here what it writes to its `ep0` and reads back.

  `layout/1` makes, from interfaces described as data, the descriptors and
  strings that a function writes to `ep0` before the gadget connects, for
  full and high speed, and tells which endpoint file (`ep1`, `ep2`...)
  each endpoint is. `events/1` reads what `ep0` gives: the gadget bound and
  enabled, a control request, suspend and resume.

      Kuroneko.Gadget.FunctionFS.layout([
        [class: 0xFF, name: "Loopback", endpoints: [{:in, :bulk}, {:out, :bulk}]]
      ])
      #=> {:ok, %{descriptors: <<3, 0, 0, 0, ...>>, strings: <<2, 0, 0, 0, ...>>,
      #=>         endpoints: [%{file: "ep1", interface: 0, direction: :in, type: :bulk},
      #=>                     %{file: "ep2", interface: 0, direction: :out, type: :bulk}]}}
  """
  import Bitwise

  @descriptors_magic_v2 3
  @strings_magic 2
  @has_fs_desc 1
  @has_hs_desc 2
  @english 0x0409

  @types %{isochronous: 1, bulk: 2, interrupt: 3}
  @syncs %{none: 0, async: 1, adaptive: 2, sync: 3}
  @intervals [1, 2, 4, 8, 16, 32, 64, 128]
  @events %{0 => :bind, 1 => :unbind, 2 => :enable, 3 => :disable, 5 => :suspend, 6 => :resume}

  @typedoc """
  An endpoint: its direction and transfer type, with options:

    * `:max_packet` - the largest packet, in bytes: for bulk endpoints at
      full speed (8, 16, 32 or 64, 64 by default; high speed has 512), for
      the others at both speeds (up to 64 for interrupt endpoints at full
      speed, 1023 for isochronous ones), 64 by default for interrupt
      endpoints and 1023 for isochronous ones
    * `:interval` - how often an interrupt or isochronous endpoint is
      served, in milliseconds: 1, 2, 4... up to 128, 1 by default
    * `:sync` - an isochronous endpoint's synchronization: `:none`,
      `:async` (the default), `:adaptive` or `:sync`
  """
  @type endpoint() ::
          {:in | :out, :bulk | :interrupt | :isochronous}
          | {:in | :out, :bulk | :interrupt | :isochronous, keyword()}

  @typedoc """
  An interface: `:class`, `:subclass` and `:protocol` (0xFF, 0 and 0 by
  default, vendor-specific), `:name`, which the host may show, and its
  `:endpoints`.
  """
  @type interface() :: keyword()

  @typedoc "Where an endpoint is, see `layout/1`."
  @type endpoint_file() :: %{
          file: String.t(),
          interface: non_neg_integer(),
          direction: :in | :out,
          type: :bulk | :interrupt | :isochronous
        }

  @typedoc "A control request to the function, from a `{:setup, request}` event."
  @type request() :: %{
          direction: :in | :out,
          type: :standard | :class | :vendor | :reserved,
          recipient: :device | :interface | :endpoint | :other,
          request: byte(),
          value: char(),
          index: char(),
          length: char()
        }

  @type event() ::
          :bind | :unbind | :enable | :disable | :suspend | :resume | {:setup, request()}

  @doc """
  The descriptors and strings of these interfaces, to write to `ep0` in
  this order, and their endpoints' files, numbered in order from `ep1`.
  """
  @spec layout([interface()]) ::
          {:ok, %{descriptors: binary(), strings: binary(), endpoints: [endpoint_file()]}}
          | {:error, term()}
  def layout(interfaces) when is_list(interfaces) and interfaces != [] do
    with {:ok, parsed} <- collect(Enum.with_index(interfaces), &interface/1) do
      names = parsed |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      numbered = number_endpoints(parsed)

      files =
        for interface <- numbered, endpoint <- interface.endpoints do
          %{
            file: "ep#{endpoint.number}",
            interface: interface.number,
            direction: endpoint.direction,
            type: endpoint.type
          }
        end

      {:ok,
       %{descriptors: descriptors(numbered, names), strings: strings(names), endpoints: files}}
    end
  end

  def layout(other), do: {:error, {:invalid_interfaces, other}}

  @doc """
  The events in what a read of `ep0` gave, 12 bytes each.
  """
  @spec events(binary()) :: [event()]
  def events(<<setup::binary-size(8), type, _pad::binary-size(3), rest::binary>>),
    do: [event(type, setup) | events(rest)]

  def events(_rest), do: []

  defp event(4, <<request_type, request, value::little-16, index::little-16, length::little-16>>) do
    {:setup,
     %{
       direction: if((request_type &&& 0x80) == 0, do: :out, else: :in),
       type: Enum.at([:standard, :class, :vendor, :reserved], request_type >>> 5 &&& 3),
       recipient:
         Map.get(%{0 => :device, 1 => :interface, 2 => :endpoint}, request_type &&& 0x1F, :other),
       request: request,
       value: value,
       index: index,
       length: length
     }}
  end

  defp event(type, _setup), do: Map.get(@events, type, {:unknown, type})

  defp interface({opts, number}) do
    known = [:class, :subclass, :protocol, :name, :endpoints]

    with true <- Keyword.keyword?(opts) || {:error, {:invalid_interface, opts}},
         [] <- Keyword.keys(opts) -- known,
         {:ok, codes} <- codes(opts),
         {:ok, name} <- name(opts[:name]),
         {:ok, endpoints} <- collect(Keyword.get(opts, :endpoints, []), &endpoint/1) do
      {:ok, Map.merge(codes, %{number: number, name: name, endpoints: endpoints})}
    else
      [_ | _] = unknown -> {:error, {:unknown_options, :interface, unknown}}
      error -> error
    end
  end

  defp codes(opts) do
    codes = %{
      class: Keyword.get(opts, :class, 0xFF),
      subclass: Keyword.get(opts, :subclass, 0),
      protocol: Keyword.get(opts, :protocol, 0)
    }

    case Enum.find(codes, fn {_key, value} -> value not in 0..255 end) do
      nil -> {:ok, codes}
      {key, value} -> {:error, {:"invalid_#{key}", value}}
    end
  end

  defp name(nil), do: {:ok, nil}

  defp name(name) when is_binary(name) do
    if String.valid?(name) and not String.contains?(name, <<0>>) and byte_size(name) <= 126,
      do: {:ok, name},
      else: {:error, {:invalid_name, name}}
  end

  defp name(name), do: {:error, {:invalid_name, name}}

  defp endpoint({direction, type}) when direction in [:in, :out] and is_map_key(@types, type),
    do: endpoint({direction, type, []})

  defp endpoint({direction, type, opts} = spec)
       when direction in [:in, :out] and is_map_key(@types, type) and is_list(opts) do
    endpoint = %{
      direction: direction,
      type: type,
      max_packet: Keyword.get(opts, :max_packet, default_packet(type)),
      interval: Keyword.get(opts, :interval, 1),
      sync: Keyword.get(opts, :sync, :async)
    }

    cond do
      Keyword.keys(opts) -- [:max_packet, :interval, :sync] != [] ->
        {:error, {:unknown_options, spec, Keyword.keys(opts) -- [:max_packet, :interval, :sync]}}

      not valid_packet?(type, endpoint.max_packet) ->
        {:error, {:invalid_max_packet, spec}}

      endpoint.interval not in @intervals ->
        {:error, {:invalid_interval, spec}}

      not is_map_key(@syncs, endpoint.sync) ->
        {:error, {:invalid_sync, spec}}

      true ->
        {:ok, endpoint}
    end
  end

  defp endpoint(other), do: {:error, {:invalid_endpoint, other}}

  defp default_packet(:bulk), do: 64
  defp default_packet(:interrupt), do: 64
  defp default_packet(:isochronous), do: 1023

  defp valid_packet?(:bulk, size), do: size in [8, 16, 32, 64]
  defp valid_packet?(:interrupt, size), do: is_integer(size) and size in 1..64
  defp valid_packet?(:isochronous, size), do: is_integer(size) and size in 1..1023

  # Endpoints in order from 1, each with a number of its own: their files.
  defp number_endpoints(interfaces) do
    {numbered, _next} =
      Enum.map_reduce(interfaces, 1, fn interface, next ->
        endpoints =
          interface.endpoints
          |> Enum.with_index(next)
          |> Enum.map(fn {e, n} -> Map.put(e, :number, n) end)

        {%{interface | endpoints: endpoints}, next + length(endpoints)}
      end)

    numbered
  end

  defp descriptors(interfaces, names) do
    full = Enum.flat_map(interfaces, &interface_descriptors(&1, names, :full))
    high = Enum.flat_map(interfaces, &interface_descriptors(&1, names, :high))
    body = IO.iodata_to_binary([full, high])

    <<@descriptors_magic_v2::little-32, byte_size(body) + 20::little-32,
      @has_fs_desc ||| @has_hs_desc::little-32, length(full)::little-32, length(high)::little-32,
      body::binary>>
  end

  defp interface_descriptors(interface, names, speed) do
    string =
      case Enum.find_index(names, &(&1 == interface.name)) do
        nil -> 0
        index -> index + 1
      end

    [
      <<9, 4, interface.number, 0, length(interface.endpoints), interface.class,
        interface.subclass, interface.protocol, string>>
      | Enum.map(interface.endpoints, &endpoint_descriptor(&1, speed))
    ]
  end

  defp endpoint_descriptor(endpoint, speed) do
    address = if endpoint.direction == :in, do: 0x80 ||| endpoint.number, else: endpoint.number

    attributes =
      @types[endpoint.type] |||
        if(endpoint.type == :isochronous, do: @syncs[endpoint.sync] <<< 2, else: 0)

    <<7, 5, address, attributes, packet(endpoint, speed)::little-16, interval(endpoint, speed)>>
  end

  defp packet(%{type: :bulk}, :high), do: 512
  defp packet(endpoint, _speed), do: endpoint.max_packet

  # Full speed counts interrupt intervals in frames of 1 ms, isochronous
  # ones as 2^(n - 1) frames; high speed both as 2^(n - 1) microframes.
  defp interval(%{type: :bulk}, _speed), do: 0
  defp interval(%{type: :interrupt, interval: ms}, :full), do: ms
  defp interval(%{interval: ms}, :full), do: log2(ms) + 1
  defp interval(%{interval: ms}, :high), do: log2(ms * 8) + 1

  defp log2(1), do: 0
  defp log2(n), do: 1 + log2(n >>> 1)

  defp strings([]), do: <<@strings_magic::little-32, 16::little-32, 0::little-32, 0::little-32>>

  defp strings(names) do
    table = [<<@english::little-16>> | Enum.map(names, &[&1, 0])]
    body = IO.iodata_to_binary(table)

    <<@strings_magic::little-32, byte_size(body) + 16::little-32, length(names)::little-32,
      1::little-32, body::binary>>
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end
end

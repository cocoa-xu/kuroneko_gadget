defmodule Kuroneko.Gadget.FunctionFS.EP0 do
  @moduledoc false

  import Bitwise

  @descriptors_magic_v2 3
  @strings_magic 2
  @has_full_and_high_speed 0x3
  @english 0x0409
  @types %{isochronous: 1, bulk: 2, interrupt: 3}
  @syncs %{none: 0, async: 1, adaptive: 2, sync: 3}
  @intervals [1, 2, 4, 8, 16, 32, 64, 128]
  @events %{0 => :bind, 1 => :unbind, 2 => :enable, 3 => :disable, 5 => :suspend, 6 => :resume}
  @interface_options [:class, :subclass, :protocol, :name, :extra, :endpoints]
  @endpoint_options [:max_packet, :interval, :sync, :extra]

  @spec encode([Kuroneko.Gadget.FunctionFS.interface()]) ::
          {:ok, %{descriptors: binary(), strings: binary(), directions: [:in | :out]}}
          | {:error, term()}
  def encode([_ | _] = interfaces) do
    with {:ok, interfaces} <- map_ok(Enum.with_index(interfaces), &interface/1) do
      interfaces = number_endpoints(interfaces)
      names = interfaces |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      {:ok,
       %{
         descriptors: descriptors(interfaces, names),
         strings: strings(names),
         directions: for(i <- interfaces, e <- i.endpoints, do: e.direction)
       }}
    end
  end

  def encode(interfaces), do: {:error, {:invalid_interfaces, interfaces}}

  @spec events(binary()) :: [Kuroneko.Gadget.FunctionFS.event()]
  def events(<<setup::binary-size(8), type, _pad::binary-size(3), rest::binary>>),
    do: [event(type, setup) | events(rest)]

  def events(<<>>), do: []

  defp event(4, <<request_type, request, value::little-16, index::little-16, length::little-16>>) do
    {:setup,
     %{
       direction: if((request_type &&& 0x80) == 0, do: :out, else: :in),
       type: Enum.at([:standard, :class, :vendor, :reserved], request_type >>> 5 &&& 3),
       recipient: recipient(request_type &&& 0x1F),
       request: request,
       value: value,
       index: index,
       length: length
     }}
  end

  defp event(type, _setup), do: Map.fetch!(@events, type)

  defp recipient(0), do: :device
  defp recipient(1), do: :interface
  defp recipient(2), do: :endpoint
  defp recipient(_other), do: :other

  defp interface({opts, number}) do
    with :ok <- check_keys(opts, @interface_options, :interface),
         {:ok, class} <- byte(opts, :class, 0xFF),
         {:ok, subclass} <- byte(opts, :subclass, 0),
         {:ok, protocol} <- byte(opts, :protocol, 0),
         {:ok, name} <- name(opts[:name]),
         {:ok, extra} <- extra(Keyword.get(opts, :extra, [])),
         {:ok, endpoints} <- map_ok(Keyword.get(opts, :endpoints, []), &endpoint/1) do
      {:ok,
       %{
         number: number,
         class: class,
         subclass: subclass,
         protocol: protocol,
         name: name,
         extra: extra,
         endpoints: endpoints
       }}
    end
  end

  defp check_keys(opts, known, what) do
    cond do
      not Keyword.keyword?(opts) -> {:error, {:invalid_options, what, opts}}
      Keyword.keys(opts) -- known == [] -> :ok
      true -> {:error, {:unknown_options, what, Keyword.keys(opts) -- known}}
    end
  end

  defp byte(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when value in 0..255 -> {:ok, value}
      value -> {:error, {:invalid_code, key, value}}
    end
  end

  defp name(nil), do: {:ok, nil}

  defp name(name) when is_binary(name) and byte_size(name) <= 126 do
    if String.valid?(name) and not String.contains?(name, <<0>>),
      do: {:ok, name},
      else: {:error, {:invalid_name, name}}
  end

  defp name(name), do: {:error, {:invalid_name, name}}

  defp extra(descriptors) when is_list(descriptors) do
    with {:ok, split} <- map_ok(descriptors, &split_descriptors/1),
         do: {:ok, List.flatten(split)}
  end

  defp extra(other), do: {:error, {:invalid_descriptor, other}}

  defp split_descriptors(binary), do: split_descriptors(binary, binary, [])

  defp split_descriptors(_whole, <<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp split_descriptors(whole, <<length, _type, _::binary>> = rest, acc)
       when length >= 2 and byte_size(rest) >= length do
    <<descriptor::binary-size(^length), rest::binary>> = rest
    split_descriptors(whole, rest, [descriptor | acc])
  end

  defp split_descriptors(whole, _rest, _acc), do: {:error, {:invalid_descriptor, whole}}

  defp endpoint({direction, type}) when direction in [:in, :out] and is_map_key(@types, type),
    do: endpoint({direction, type, []})

  defp endpoint({direction, type, opts} = spec)
       when direction in [:in, :out] and is_map_key(@types, type) do
    with :ok <- check_keys(opts, @endpoint_options, :endpoint),
         {:ok, max_packet} <-
           max_packet(type, Keyword.get(opts, :max_packet, default_packet(type))),
         {:ok, interval} <- interval(Keyword.get(opts, :interval, 1)),
         {:ok, sync} <- sync(Keyword.get(opts, :sync, :async)),
         {:ok, extra} <- extra(Keyword.get(opts, :extra, [])) do
      {:ok,
       %{
         direction: direction,
         type: type,
         max_packet: max_packet,
         interval: interval,
         sync: sync,
         extra: extra
       }}
    else
      {:error, reason} -> {:error, {spec, reason}}
    end
  end

  defp endpoint(other), do: {:error, {:invalid_endpoint, other}}

  defp default_packet(:isochronous), do: 1023
  defp default_packet(_bulk_or_interrupt), do: 64

  defp max_packet(:bulk, size) when size in [8, 16, 32, 64], do: {:ok, size}
  defp max_packet(:interrupt, size) when size in 1..64, do: {:ok, size}
  defp max_packet(:isochronous, size) when size in 1..1023, do: {:ok, size}
  defp max_packet(_type, size), do: {:error, {:invalid_max_packet, size}}

  defp interval(ms) when ms in @intervals, do: {:ok, ms}
  defp interval(ms), do: {:error, {:invalid_interval, ms}}

  defp sync(sync) when is_map_key(@syncs, sync), do: {:ok, sync}
  defp sync(sync), do: {:error, {:invalid_sync, sync}}

  defp number_endpoints(interfaces) do
    {numbered, _next} =
      Enum.map_reduce(interfaces, 1, fn interface, next ->
        endpoints =
          interface.endpoints
          |> Enum.with_index(next)
          |> Enum.map(fn {endpoint, number} -> Map.put(endpoint, :number, number) end)

        {%{interface | endpoints: endpoints}, next + length(endpoints)}
      end)

    numbered
  end

  defp descriptors(interfaces, names) do
    full = Enum.flat_map(interfaces, &interface_descriptors(&1, names, :full))
    high = Enum.flat_map(interfaces, &interface_descriptors(&1, names, :high))
    body = IO.iodata_to_binary([full, high])

    <<@descriptors_magic_v2::little-32, byte_size(body) + 20::little-32,
      @has_full_and_high_speed::little-32, length(full)::little-32, length(high)::little-32,
      body::binary>>
  end

  defp interface_descriptors(interface, names, speed) do
    string = if interface.name, do: Enum.find_index(names, &(&1 == interface.name)) + 1, else: 0

    [
      <<9, 4, interface.number, 0, length(interface.endpoints), interface.class,
        interface.subclass, interface.protocol, string>>
      | interface.extra
    ] ++ Enum.flat_map(interface.endpoints, &[endpoint_descriptor(&1, speed) | &1.extra])
  end

  defp endpoint_descriptor(endpoint, speed) do
    address = if endpoint.direction == :in, do: 0x80 ||| endpoint.number, else: endpoint.number
    attributes = @types[endpoint.type] ||| sync_bits(endpoint)

    <<7, 5, address, attributes, packet_size(endpoint, speed)::little-16,
      polling(endpoint, speed)>>
  end

  defp sync_bits(%{type: :isochronous, sync: sync}), do: @syncs[sync] <<< 2
  defp sync_bits(_endpoint), do: 0

  defp packet_size(%{type: :bulk}, :high), do: 512
  defp packet_size(endpoint, _speed), do: endpoint.max_packet

  # Full speed counts interrupt intervals in 1 ms frames and isochronous ones
  # as 2^(n - 1) frames; high speed counts both as 2^(n - 1) microframes.
  defp polling(%{type: :bulk}, _speed), do: 0
  defp polling(%{type: :interrupt, interval: ms}, :full), do: ms
  defp polling(%{interval: ms}, :full), do: log2(ms) + 1
  defp polling(%{interval: ms}, :high), do: log2(ms * 8) + 1

  defp log2(1), do: 0
  defp log2(n), do: 1 + log2(n >>> 1)

  defp strings([]), do: <<@strings_magic::little-32, 16::little-32, 0::little-32, 0::little-32>>

  defp strings(names) do
    body = IO.iodata_to_binary([<<@english::little-16>> | Enum.map(names, &[&1, 0])])

    <<@strings_magic::little-32, byte_size(body) + 16::little-32, length(names)::little-32,
      1::little-32, body::binary>>
  end

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

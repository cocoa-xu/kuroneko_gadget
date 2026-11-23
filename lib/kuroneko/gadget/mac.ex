defmodule Kuroneko.Gadget.MAC do
  @moduledoc false

  import Bitwise

  @spec parse(term()) :: {:ok, <<_::48>>} | :error
  def parse(text) when is_binary(text) do
    with [_, _, _, _, _, _] = parts <- String.split(text, [":", "-"]),
         true <- Enum.all?(parts, &(byte_size(&1) == 2)),
         {:ok, bytes} <- Base.decode16(Enum.join(parts), case: :mixed) do
      {:ok, bytes}
    else
      _not_an_address -> :error
    end
  end

  def parse(_other), do: :error

  @spec format(<<_::48>>) :: String.t()
  def format(bytes),
    do: Enum.map_join(:binary.bin_to_list(bytes), ":", &Base.encode16(<<&1>>, case: :lower))

  @spec multicast?(<<_::48>>) :: boolean()
  def multicast?(<<first, _rest::binary>>), do: (first &&& 1) == 1

  # Locally administered and unicast, the same on every boot.
  @spec derive(String.t(), String.t(), String.t()) :: String.t()
  def derive(serial, name, role) do
    <<first, rest::binary-size(5), _::binary>> = :crypto.hash(:sha256, [serial, 0, name, 0, role])
    format(<<(first &&& 0xFC) ||| 0x02, rest::binary>>)
  end
end

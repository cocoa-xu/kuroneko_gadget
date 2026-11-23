defmodule Kuroneko.Gadget.Serial do
  @moduledoc """
  A serial port between the device and the target computer (USB CDC ACM),
  a function for `Kuroneko.Gadget`:

      Kuroneko.Gadget.configure([:keyboard, :mouse, Kuroneko.Gadget.Serial])
      Kuroneko.Gadget.Serial.tty()
      #=> {:ok, "/dev/ttyGS0"}

  The target sees a modem: Linux as `/dev/ttyACM0`, macOS as
  `/dev/cu.usbmodem...`, Windows as a COM port, which a console, a
  terminal program or a script on the target can use. The device's end is
  `tty/1`. The speed and the line settings are the target's to choose; the
  data goes as fast as USB takes it either way.

  Each port takes two IN endpoints and one OUT. Several have their names:
  `{Kuroneko.Gadget.Serial, name: "console"}`.
  """
  @behaviour Kuroneko.Gadget.Function

  @impl Kuroneko.Gadget.Function
  def type, do: "acm"

  @impl Kuroneko.Gadget.Function
  def default_name, do: "serial"

  @impl Kuroneko.Gadget.Function
  def settings([]), do: {:ok, %{}}
  def settings(opts), do: {:error, {:unknown_options, __MODULE__, Keyword.keys(opts)}}

  @impl Kuroneko.Gadget.Function
  def endpoints(_settings), do: {2, 1}

  @impl Kuroneko.Gadget.Function
  def setup(_dir, _settings), do: :ok

  @impl Kuroneko.Gadget.Function
  def read(_dir), do: {:ok, %{}}

  @doc """
  The device's end of the port, such as `"/dev/ttyGS0"`: the default
  port's, or that of the one `:name` names. Takes the `:gadget` option.
  """
  @spec tty(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def tty(opts \\ []) do
    port = Path.join(Kuroneko.Gadget.function_dir(__MODULE__, opts), "port_num")

    with {:ok, text} <- File.read(port),
         {number, _rest} <- Integer.parse(String.trim(text)) do
      {:ok, "/dev/ttyGS#{number}"}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :no_port}
    end
  end
end

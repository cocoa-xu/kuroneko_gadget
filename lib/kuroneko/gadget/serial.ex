defmodule Kuroneko.Gadget.Serial do
  @moduledoc """
  A serial port between the device and the target computer, over USB CDC
  ACM.

      Kuroneko.Gadget.configure([:keyboard, :mouse, Kuroneko.Gadget.Serial])
      Kuroneko.Gadget.Serial.tty()
      #=> {:ok, "/dev/ttyGS0"}

  The target sees a modem: `/dev/ttyACM0` on Linux, `/dev/cu.usbmodem...` on
  macOS, a COM port on Windows. Each port takes two IN endpoints and one
  OUT; more than one need names, such as `{Kuroneko.Gadget.Serial, name:
  "console"}`.

  Read the device's end with a port program such as `Circuits.UART`: a
  `File` read blocks one of the VM's dirty I/O schedulers until data comes,
  and nothing can call it off.
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
  def endpoints(%{}), do: {2, 1}

  @impl Kuroneko.Gadget.Function
  def setup(_dir, %{}), do: :ok

  @doc """
  The device's end of the port, such as `"/dev/ttyGS0"`: the default
  port's, or that of the one `:name` names. Takes the `:gadget` option.
  """
  @spec tty(keyword()) :: {:ok, Path.t()} | {:error, File.posix()}
  def tty(opts \\ []) do
    port_num = Path.join(Kuroneko.Gadget.function_dir(__MODULE__, opts), "port_num")

    with {:ok, number} <- File.read(port_num),
         do: {:ok, "/dev/ttyGS" <> String.trim(number)}
  end
end

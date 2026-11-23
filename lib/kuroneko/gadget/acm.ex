defmodule Kuroneko.Gadget.ACM do
  @moduledoc """
  The kernel's CDC ACM function: a serial port between the device and the
  target computer.

      Kuroneko.Gadget.configure([:keyboard, :mouse, Kuroneko.Gadget.ACM])
      Kuroneko.Gadget.ACM.tty()
      #=> {:ok, "/dev/ttyGS0"}

  The target sees a modem: `/dev/ttyACM0` on Linux, `/dev/cu.usbmodem...` on
  macOS, a COM port on Windows. Each port takes two IN endpoints and one
  OUT; more than one need names, such as `{Kuroneko.Gadget.ACM, name:
  "console"}`. It takes no options.

  Read the device's end with a port program such as `Circuits.UART`: a
  `File` read blocks one of the VM's dirty I/O schedulers until data comes,
  and nothing can call it off.
  """

  @behaviour Kuroneko.Gadget.Function

  alias Kuroneko.Gadget.Configfs

  @impl Kuroneko.Gadget.Function
  def type, do: "acm"

  @impl Kuroneko.Gadget.Function
  def default_name, do: "serial"

  @impl Kuroneko.Gadget.Function
  def settings([]), do: {:ok, %{}}
  def settings(opts), do: {:error, {:unknown_options, __MODULE__, Keyword.keys(opts)}}

  @impl Kuroneko.Gadget.Function
  def endpoints(%{}), do: %{in: 2, out: 1}

  @impl Kuroneko.Gadget.Function
  def setup(_dir, %{}), do: :ok

  @doc """
  The device's end of a port, such as `"/dev/ttyGS0"`: the one `:name`
  names, `"serial"` by default. Takes the `:gadget` option.
  """
  @spec tty(keyword()) :: {:ok, Path.t()} | {:error, Kuroneko.Gadget.configfs_error()}
  def tty(opts \\ []) do
    port_num = Path.join(Kuroneko.Gadget.function_dir(__MODULE__, opts), "port_num")
    with {:ok, number} <- Configfs.read_text(port_num), do: {:ok, "/dev/ttyGS" <> number}
  end
end

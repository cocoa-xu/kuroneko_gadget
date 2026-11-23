defmodule Kuroneko.Gadget.NCM do
  @moduledoc """
  The kernel's NCM function: a USB network adapter the target computer
  sees, with a network interface on the device.

  An instance has two MAC addresses: the device's, of its interface, and
  the target's, of the adapter the target sees. They are made from the
  gadget's serial number and the instance's name, so they stay the same
  across boots. The `:network` of `Kuroneko.Gadget` is an instance named
  `"usb0"`, whose addresses `Kuroneko.Gadget.network/1` tells and
  `Kuroneko.Gadget.set_network_addresses/2` changes.

  It takes no options.
  """

  @behaviour Kuroneko.Gadget.Function

  alias Kuroneko.Gadget.Configfs
  alias Kuroneko.Gadget.MAC

  @typedoc ~s(A MAC address, such as `"02:12:34:56:78:9a"`.)
  @type address() :: String.t()

  @type addresses() :: %{device_address: address(), host_address: address()}

  @impl Kuroneko.Gadget.Function
  def type, do: "ncm"

  @impl Kuroneko.Gadget.Function
  def default_name, do: "usb0"

  @impl Kuroneko.Gadget.Function
  def settings([]), do: {:ok, %{}}
  def settings(opts), do: {:error, {:unknown_options, __MODULE__, Keyword.keys(opts)}}

  @impl Kuroneko.Gadget.Function
  def endpoints(%{}), do: %{in: 2, out: 1}

  @impl Kuroneko.Gadget.Function
  def setup(dir, %{}) do
    gadget = dir |> Path.dirname() |> Path.dirname()
    "ncm." <> name = Path.basename(dir)

    serial =
      case Configfs.read_text(Path.join(gadget, "strings/0x409/serialnumber")) do
        {:ok, serial} -> serial
        {:error, _no_serial} -> ""
      end

    write_addresses(dir, %{
      device_address: MAC.derive(serial, name, "device"),
      host_address: MAC.derive(serial, name, "host")
    })
  end

  @impl Kuroneko.Gadget.Function
  def read(_dir), do: {:ok, %{}}

  @doc """
  The addresses of an instance: the one `:name` names, `"usb0"` by
  default. Takes the `:gadget` option.
  """
  @spec addresses(keyword()) :: {:ok, addresses()} | {:error, Kuroneko.Gadget.configfs_error()}
  def addresses(opts \\ []), do: read_addresses(Kuroneko.Gadget.function_dir(__MODULE__, opts))

  @doc """
  The device's network interface of an instance, such as `"usb0"`, `nil`
  before the gadget first connects. Takes `:name` and `:gadget`.
  """
  @spec interface(keyword()) :: String.t() | nil
  def interface(opts \\ []), do: read_interface(Kuroneko.Gadget.function_dir(__MODULE__, opts))

  @doc false
  @spec read_addresses(Path.t()) ::
          {:ok, addresses()} | {:error, Kuroneko.Gadget.configfs_error()}
  def read_addresses(dir) do
    with {:ok, device} <- read_address(dir, "dev_addr"),
         {:ok, host} <- read_address(dir, "host_addr"),
         do: {:ok, %{device_address: device, host_address: host}}
  end

  # An interface not registered yet is "(unnamed net_device)".
  @doc false
  @spec read_interface(Path.t()) :: String.t() | nil
  def read_interface(dir) do
    case Configfs.read_text(Path.join(dir, "ifname")) do
      {:ok, "(" <> _unnamed} -> nil
      {:ok, name} -> name
      {:error, _reason} -> nil
    end
  end

  @doc false
  @spec write_addresses(Path.t(), addresses()) :: :ok | {:error, Kuroneko.Gadget.configfs_error()}
  def write_addresses(dir, %{device_address: device, host_address: host}),
    do: Configfs.write_all(dir, [{"dev_addr", device}, {"host_addr", host}])

  # The device's address is its interface's, which the function makes when
  # it is first bound: another one takes a new function, with the settings
  # of the old. The function is out of the configuration.
  @doc false
  @spec readdress(Path.t(), addresses(), addresses()) ::
          :ok | {:error, Kuroneko.Gadget.configfs_error()}
  def readdress(dir, current, wanted) when current.device_address == wanted.device_address,
    do: Configfs.write(Path.join(dir, "host_addr"), wanted.host_address)

  def readdress(dir, _current, wanted) do
    kept =
      for attribute <- ["qmult", "max_segment_size"],
          {:ok, value} <- [Configfs.read_text(Path.join(dir, attribute))],
          do: {attribute, value}

    with :ok <- Configfs.rmdir(dir),
         :ok <- Configfs.mkdir(dir),
         :ok <- Configfs.write_all(dir, kept),
         do: write_addresses(dir, wanted)
  end

  # configfs shows an address with a NUL and a newline after it.
  defp read_address(dir, attribute) do
    with {:ok, text} <- Configfs.read(Path.join(dir, attribute)) do
      {:ok, bytes} = text |> String.replace(["\0", "\n"], "") |> MAC.parse()
      {:ok, MAC.format(bytes)}
    end
  end
end

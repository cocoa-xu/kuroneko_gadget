defmodule Kuroneko.Gadget.HID do
  @moduledoc """
  The kernel's HID function: a keyboard, a mouse, a game controller, any
  device a HID report descriptor describes. A program writes its reports
  to the instance's device file.

      pad = %{report_desc: File.read!("pad.bin"), report_length: 4}
      Kuroneko.Gadget.configure([{Kuroneko.Gadget.HID, name: "pad", descriptor: pad}])
      {:ok, path} = Kuroneko.Gadget.HID.device(name: "pad")

  The `:keyboard`, `:mouse` and `:relative_mouse` of `Kuroneko.Gadget` are
  instances with the descriptors of `descriptor/1`, which
  `Kuroneko.Gadget.Input` drives.

  ## Options

    * `:descriptor` - a map with the `:report_desc`, the `:report_length` of
      the longest input report, and the boot `:protocol` and `:subclass`: 1
      and 1 for a keyboard, 2 and 1 for a mouse, 0 and 0 by default. Or a
      descriptor of `descriptor/1`, by its name.
  """

  @behaviour Kuroneko.Gadget.Function

  alias Kuroneko.Gadget.Configfs
  alias Kuroneko.Gadget.HID.Descriptor

  @type descriptor() :: %{
          report_desc: binary(),
          report_length: pos_integer(),
          protocol: 0..2,
          subclass: 0..1
        }

  @typedoc """
  The built-in descriptors: a boot keyboard, the absolute pointer as a
  mouse, a pen (for Android and iPadOS) or a touch screen, and a relative
  boot mouse.
  """
  @type builtin() :: :keyboard | :mouse | :stylus | :touch | :relative_mouse

  @builtins [:keyboard, :mouse, :stylus, :touch, :relative_mouse]

  @impl Kuroneko.Gadget.Function
  def type, do: "hid"

  @impl Kuroneko.Gadget.Function
  def default_name, do: "hid"

  @impl Kuroneko.Gadget.Function
  def settings(opts) do
    case Keyword.validate(opts, [:descriptor]) do
      {:ok, opts} -> check_descriptor(opts[:descriptor])
      {:error, unknown} -> {:error, {:unknown_options, __MODULE__, unknown}}
    end
  end

  @impl Kuroneko.Gadget.Function
  def endpoints(_descriptor), do: %{in: 1, out: 0}

  # No OUT endpoint where the kernel allows: the keyboard's LEDs come over
  # the control endpoint, and the other functions need the endpoints.
  @impl Kuroneko.Gadget.Function
  def setup(dir, descriptor) do
    with :ok <-
           Configfs.write_all(dir, [
             {"protocol", Integer.to_string(descriptor.protocol)},
             {"subclass", Integer.to_string(descriptor.subclass)},
             {"report_length", Integer.to_string(descriptor.report_length)},
             {"report_desc", descriptor.report_desc}
           ]) do
      Configfs.write_existing(dir, [{"no_out_endpoint", "1"}])
    end
  end

  @impl Kuroneko.Gadget.Function
  def read(dir) do
    with {:ok, protocol} <- Configfs.read_integer(Path.join(dir, "protocol")),
         {:ok, subclass} <- Configfs.read_integer(Path.join(dir, "subclass")),
         {:ok, report_length} <- Configfs.read_integer(Path.join(dir, "report_length")),
         {:ok, report_desc} <- Configfs.read(Path.join(dir, "report_desc")) do
      {:ok,
       %{
         report_desc: report_desc,
         report_length: report_length,
         protocol: protocol,
         subclass: subclass
       }}
    else
      {:error, _reason} -> :error
    end
  end

  @doc "A built-in descriptor."
  @spec descriptor(builtin()) :: descriptor()
  def descriptor(name) when name in @builtins, do: Descriptor.builtin(name)

  @doc "The name of a built-in descriptor, `nil` for another one."
  @spec builtin(descriptor()) :: builtin() | nil
  def builtin(descriptor), do: Enum.find(@builtins, &(Descriptor.builtin(&1) == descriptor))

  @doc """
  The device file of an instance, such as `"/dev/hidg0"`: the one `:name`
  names, `"hid"` by default. Takes the `:gadget` option.
  """
  @spec device(keyword()) :: {:ok, Path.t()} | {:error, Kuroneko.Gadget.configfs_error()}
  def device(opts \\ []) do
    dir = Kuroneko.Gadget.function_dir(__MODULE__, opts)

    with {:ok, numbers} <- Configfs.read_text(Path.join(dir, "dev")),
         {:ok, uevent} <- Configfs.read(Path.join(["/sys/dev/char", numbers, "uevent"])) do
      [_line, name] = Regex.run(~r/^DEVNAME=(.+)$/m, uevent)
      {:ok, "/dev/" <> name}
    end
  end

  defp check_descriptor(name) when name in @builtins, do: {:ok, Descriptor.builtin(name)}

  defp check_descriptor(%{report_desc: report_desc, report_length: report_length} = descriptor)
       when is_binary(report_desc) and report_desc != "" and is_integer(report_length) and
              report_length > 0 do
    protocol = Map.get(descriptor, :protocol, 0)
    subclass = Map.get(descriptor, :subclass, 0)

    if protocol in 0..2 and subclass in 0..1 and
         Map.keys(descriptor) -- [:report_desc, :report_length, :protocol, :subclass] == [],
       do:
         {:ok,
          %{
            report_desc: report_desc,
            report_length: report_length,
            protocol: protocol,
            subclass: subclass
          }},
       else: {:error, {:invalid_descriptor, descriptor}}
  end

  defp check_descriptor(other), do: {:error, {:invalid_descriptor, other}}
end

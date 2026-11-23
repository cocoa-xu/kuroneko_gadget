defmodule Kuroneko.Gadget.Function do
  @moduledoc """
  A kind of USB function of your own for `Kuroneko.Gadget`, besides its
  keyboard, mice, storage, network and sound card: a serial port, such as
  `Kuroneko.Gadget.Serial`, a MIDI device, a camera, a printer, or a device
  of your own through FunctionFS. It goes in the functions as the built-in
  kinds do, as many times as it has names:

      Kuroneko.Gadget.configure([:keyboard, Kuroneko.Gadget.Serial, {MyPad, name: "pad"}])

  The gadget makes each instance's configfs directory, `type.name`, has the
  module set up its attributes, links it into the configuration after the
  built-in kinds, counts its endpoints against the controller's, and tells
  it apart among the functions on the gadget by its type and name. An
  instance whose settings change is made again; one that the functions
  leave out is removed.

  The kernel's configfs functions are in its
  `Documentation/ABI/testing/configfs-usb-gadget-*`: their types (`"acm"`,
  `"midi"`, `"uvc"`, `"printer"`...) and attributes. FunctionFS (`"ffs"`)
  leaves the descriptors and the endpoints to a process of yours, which
  readies the function in `c:ready/2`.

  Settings are plain data, compared with `==`. An exception in a callback
  is an error of the change, which leaves the functions as they were.
  """

  @typedoc "What an instance keeps of its options, as `c:settings/1` gives it."
  @type settings() :: term()

  @doc ~s(The configfs function type: `"acm"`, `"midi"`, `"ffs"`...)
  @callback type() :: String.t()

  @doc "An instance's name when none is given."
  @callback default_name() :: String.t()

  @doc "Checks an instance's options, `:name` aside, and gives its settings."
  @callback settings(keyword()) :: {:ok, settings()} | {:error, term()}

  @doc "The endpoints an instance takes besides endpoint 0: `{in, out}`."
  @callback endpoints(settings()) :: {non_neg_integer(), non_neg_integer()}

  @doc "Sets up the attributes of an instance's new configfs directory."
  @callback setup(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @doc """
  The settings of the instance in `dir`, `:error` when it is not one of
  this module's. Without it, an instance of the type and name is taken as
  it was asked for.
  """
  @callback read(dir :: Path.t()) :: {:ok, settings()} | :error

  @doc """
  Readies an instance in the configuration, each time before the gadget
  connects and when the functions are configured again unchanged: a
  FunctionFS function starts its process if it is not running. When this
  takes the gadget off the bus, as FunctionFS does, the gadget connects
  again.
  """
  @callback ready(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @doc """
  Lets an instance go: it is out of the configuration, or its `c:setup/2`
  failed, and its directory is removed next. A FunctionFS function closes
  its endpoints and unmounts.
  """
  @callback teardown(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @optional_callbacks read: 1, ready: 2, teardown: 2

  @doc false
  @spec function?(term()) :: boolean()
  def function?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      Enum.all?(
        [type: 0, default_name: 0, settings: 1, endpoints: 1, setup: 2],
        fn {name, arity} -> function_exported?(module, name, arity) end
      )
  end
end

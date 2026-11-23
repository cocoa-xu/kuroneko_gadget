defmodule Kuroneko.Gadget.Function do
  @moduledoc """
  A kind of USB function the kernel provides, for `Kuroneko.Gadget`.

  Linux sorts USB gadget functions by driver: HID, mass storage, the
  network functions (NCM, ECM, RNDIS...), USB Audio, serial ports,
  FunctionFS. A module implementing this behaviour is one such driver,
  whose configfs attributes are its settings:
  `Kuroneko.Gadget.HID`, `Kuroneko.Gadget.MassStorage`,
  `Kuroneko.Gadget.NCM`, `Kuroneko.Gadget.UAC2`, `Kuroneko.Gadget.ACM`
  and `Kuroneko.Gadget.FunctionFS` come with this library.

  An instance goes in the functions as `{Module, name: "x", ...}`, or
  `Module` alone for its default name, the options besides `:name` being
  the module's:

      Kuroneko.Gadget.configure([
        {Kuroneko.Gadget.HID, name: "pad", descriptor: %{report_desc: pad, report_length: 4}},
        Kuroneko.Gadget.ACM
      ])

  The gadget creates each instance's configfs directory, `type.name`, has
  the module set it up, links it into the configuration and counts its
  endpoints against the controller's. An instance whose settings change is
  changed in place where the module can, else created anew; one left out is
  removed.

  Settings are compared with `==`. An exception in `c:setup/2`,
  `c:update/3`, `c:ready/2` or `c:teardown/2` fails the change, which leaves
  the functions as they were.
  """

  @type settings() :: term()

  @doc ~s(The configfs function type, such as `"hid"` or `"mass_storage"`.)
  @callback type() :: String.t()

  @doc "The name of an instance given without one."
  @callback default_name() :: String.t()

  @doc "Checks an instance's options, `:name` aside, and returns its settings."
  @callback settings(keyword()) :: {:ok, settings()} | {:error, term()}

  @doc "The endpoints an instance takes besides endpoint 0."
  @callback endpoints(settings()) :: %{in: non_neg_integer(), out: non_neg_integer()}

  @doc "Sets up the attributes in an instance's new configfs directory."
  @callback setup(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @doc """
  The settings of the instance in `dir`, or `:error` when it is not one of
  this module's. Without it, an instance found on the gadget is taken to
  have the settings it was set up with or asked for.
  """
  @callback read(dir :: Path.t()) :: {:ok, settings()} | :error

  @doc """
  Changes an instance's settings in place, while it is out of the
  configuration. Without it, an instance whose settings change is created
  anew.
  """
  @callback update(dir :: Path.t(), from :: settings(), to :: settings()) ::
              :ok | {:error, term()}

  @doc """
  Readies an instance before the gadget connects, and again whenever the
  functions are configured. When this takes the gadget off the bus, as
  FunctionFS does, the gadget connects again.
  """
  @callback ready(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @doc "Releases an instance before its directory is removed."
  @callback teardown(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @optional_callbacks read: 1, update: 3, ready: 2, teardown: 2
end

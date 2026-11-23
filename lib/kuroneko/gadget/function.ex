defmodule Kuroneko.Gadget.Function do
  @moduledoc """
  A kind of USB function for `Kuroneko.Gadget` besides the built-in ones.

  A module implementing this behaviour goes in the functions like a
  built-in kind, as `MyFunction` or `{MyFunction, name: "x", ...}`, where
  the options besides `:name` are the module's to check:

      Kuroneko.Gadget.configure([:keyboard, Kuroneko.Gadget.Serial, {MyPad, name: "pad"}])

  The gadget creates each instance's configfs directory, `type.name`, has
  the module set it up, links it into the configuration and counts its
  endpoints against the controller's. An instance whose settings change is
  created anew, and one left out is removed.

  `Kuroneko.Gadget.Serial` implements it with a function of the kernel; a
  module that uses `Kuroneko.Gadget.FunctionFS` is a function written in
  Elixir.

  Settings are compared with `==`. An exception in a callback fails the
  change, which leaves the functions as they were.
  """

  @type settings() :: term()

  @doc ~s(The configfs function type, such as `"acm"`, `"midi"` or `"ffs"`.)
  @callback type() :: String.t()

  @doc "The name of an instance given without one."
  @callback default_name() :: String.t()

  @doc "Checks an instance's options, `:name` aside, and returns its settings."
  @callback settings(keyword()) :: {:ok, settings()} | {:error, term()}

  @doc "The endpoints an instance takes besides endpoint 0, as `{in, out}`."
  @callback endpoints(settings()) :: {non_neg_integer(), non_neg_integer()}

  @doc "Sets up the attributes in an instance's new configfs directory."
  @callback setup(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @doc """
  Readies an instance before the gadget connects, and again whenever the
  functions are configured. When this takes the gadget off the bus, as
  FunctionFS does, the gadget connects again.
  """
  @callback ready(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @doc "Releases an instance before its directory is removed."
  @callback teardown(dir :: Path.t(), settings()) :: :ok | {:error, term()}

  @optional_callbacks ready: 2, teardown: 2
end

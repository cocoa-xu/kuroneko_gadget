defmodule Kuroneko.Gadget.FunctionFS do
  @moduledoc """
  USB functions written in Elixir, on the kernel's FunctionFS.

  A module that uses this one describes its interfaces as data and handles
  the function's events in a process of its own:

      defmodule Loopback do
        use Kuroneko.Gadget.FunctionFS

        alias Kuroneko.Gadget.FunctionFS

        @impl FunctionFS
        def interfaces(_settings) do
          [[name: "Loopback", endpoints: [{:in, :bulk}, {:out, :bulk}]]]
        end

        @impl FunctionFS
        def handle_event(:enable, state) do
          FunctionFS.read(self(), 2, 512)
          {:noreply, state}
        end

        def handle_event({:data, 2, data}, state) do
          FunctionFS.write(self(), 1, data)
          FunctionFS.read(self(), 2, 512)
          {:noreply, state}
        end

        def handle_event(event, state), do: super(event, state)
      end

      Kuroneko.Gadget.configure([:keyboard, :mouse, Loopback])

  Such a module is a `Kuroneko.Gadget.Function` of the type `"ffs"`. It goes
  in the functions as `Loopback`, or as `{Loopback, name: "loop2", ...}`,
  whose options besides `:name` are the settings its callbacks get. The
  endpoints are numbered from 1 in the order of `c:interfaces/1`.

  The process starts when the gadget readies the function and stops when
  the function is removed. `write/3`, `read/3`, `answer/2` and `stall/1`
  ask it for transfers, from a callback with `self()` or from elsewhere
  with `whereis/2`, and their results come back as events. An exception in
  a callback is logged and the function goes on.
  """

  alias __MODULE__
  alias Kuroneko.Gadget.Function, as: GadgetFunction
  alias Kuroneko.Gadget.FunctionFS.EP0
  alias Kuroneko.Gadget.FunctionFS.Server

  @registry Kuroneko.Gadget.FunctionFS.Registry

  @typedoc """
  An endpoint: its direction and transfer type, with options:

    * `:max_packet` - the largest packet in bytes. For bulk endpoints it
      applies at full speed: 8, 16, 32 or 64 (the default), high speed
      always having 512. Interrupt endpoints take up to 64 (the default),
      isochronous ones up to 1023 (the default).
    * `:interval` - how often an interrupt or isochronous endpoint is
      served, in milliseconds: 1 (the default), 2, 4 and so on up to 128
    * `:sync` - an isochronous endpoint's synchronization: `:none`,
      `:async` (the default), `:adaptive` or `:sync`
    * `:extra` - class-specific descriptors that follow the endpoint's
  """
  @type endpoint() ::
          {:in | :out, :bulk | :interrupt | :isochronous}
          | {:in | :out, :bulk | :interrupt | :isochronous, keyword()}

  @typedoc """
  An interface, with options:

    * `:class`, `:subclass`, `:protocol` - its codes, 0xFF, 0 and 0 by
      default: vendor-specific
    * `:name` - a name the host may show
    * `:extra` - class-specific descriptors that follow the interface's
    * `:endpoints` - its endpoints
  """
  @type interface() :: keyword()

  @typedoc "A control request to the function."
  @type request() :: %{
          direction: :in | :out,
          type: :standard | :class | :vendor | :reserved,
          recipient: :device | :interface | :endpoint | :other,
          request: byte(),
          value: char(),
          index: char(),
          length: char()
        }

  @typedoc """
  What happens to the function:

    * `:bind` and `:unbind` - the gadget puts the function on and off the bus
    * `:enable` and `:disable` - the host starts and stops using it; the
      endpoints carry data in between
    * `:suspend` and `:resume` - the bus sleeps and wakes
    * `{:setup, request}` - a control request, which waits for `answer/2`
      or `stall/1` for two seconds and is stalled after that
    * `{:control_data, data}` - the data of an OUT request that `answer/2`
      took
    * `{:control_error, reason}` - an answer or stall that failed
    * `{:data, endpoint, data}` - what a `read/3` got
    * `{:written, endpoint, bytes}` - a `write/3` done
    * `{:error, endpoint, reason}` - a read or write that failed, such as
      with `:eshutdown` when the host disables the function
  """
  @type event() ::
          :bind
          | :unbind
          | :enable
          | :disable
          | :suspend
          | :resume
          | {:setup, request()}
          | {:control_data, binary()}
          | {:control_error, term()}
          | {:data, pos_integer(), binary()}
          | {:written, pos_integer(), non_neg_integer()}
          | {:error, pos_integer(), term()}

  @doc "The function's interfaces with these settings."
  @callback interfaces(settings :: term()) :: [interface()]

  @doc "The process's state from the settings: by default, the settings."
  @callback init(settings :: term()) :: {:ok, state :: term()} | {:error, term()}

  @doc """
  Handles an event: by default, stalls control requests and ignores the
  rest.
  """
  @callback handle_event(event(), state :: term()) :: {:noreply, state :: term()}

  @doc "Handles any other message to the process."
  @callback handle_info(message :: term(), state :: term()) :: {:noreply, state :: term()}

  @optional_callbacks handle_info: 2

  @doc false
  defmacro __using__(_opts) do
    default_name = __CALLER__.module |> Module.split() |> List.last() |> Macro.underscore()

    quote do
      @behaviour GadgetFunction
      @behaviour FunctionFS

      @impl GadgetFunction
      def type, do: "ffs"

      @impl GadgetFunction
      def default_name, do: unquote(default_name)

      @impl GadgetFunction
      def settings(opts) do
        settings = Map.new(opts)

        with {:ok, _ep0} <- EP0.encode(interfaces(settings)), do: {:ok, settings}
      end

      @impl GadgetFunction
      def endpoints(settings) do
        {:ok, %{directions: directions}} = EP0.encode(interfaces(settings))
        {Enum.count(directions, &(&1 == :in)), Enum.count(directions, &(&1 == :out))}
      end

      @impl GadgetFunction
      def setup(_dir, _settings), do: :ok

      @impl GadgetFunction
      def ready(dir, settings), do: Server.ready(__MODULE__, dir, settings)

      @impl GadgetFunction
      def teardown(dir, _settings), do: Server.teardown(dir)

      @impl FunctionFS
      def init(settings), do: {:ok, settings}

      @impl FunctionFS
      def handle_event({:setup, _request}, state) do
        FunctionFS.stall(self())
        {:noreply, state}
      end

      def handle_event(_event, state), do: {:noreply, state}

      defoverridable default_name: 0, settings: 1, init: 1, handle_event: 2
    end
  end

  @doc """
  Writes `data` to an IN endpoint for the host to read; `{:written,
  endpoint, bytes}` follows. An empty binary sends a packet of zero length.
  """
  @spec write(GenServer.server(), pos_integer(), binary()) :: :ok
  def write(server, endpoint, data) when is_integer(endpoint) and is_binary(data),
    do: GenServer.cast(server, {:write, endpoint, data})

  @doc """
  Reads up to `size` bytes, best a multiple of the packet size, from an
  OUT endpoint; `{:data, endpoint, data}` follows when the host sends them.
  """
  @spec read(GenServer.server(), pos_integer(), non_neg_integer()) :: :ok
  def read(server, endpoint, size) when is_integer(endpoint) and is_integer(size) and size >= 0,
    do: GenServer.cast(server, {:read, endpoint, size})

  @doc """
  Answers the pending control request: an IN request with `data`, an OUT
  one by taking the data it carries, which `{:control_data, data}` brings.
  """
  @spec answer(GenServer.server(), binary()) :: :ok
  def answer(server, data \\ <<>>) when is_binary(data),
    do: GenServer.cast(server, {:answer, data})

  @doc "Stalls the pending control request."
  @spec stall(GenServer.server()) :: :ok
  def stall(server), do: GenServer.cast(server, :stall)

  @doc """
  The process of a module's function: the default instance's, or that of
  the one `:name` names. Takes the `:gadget` option.
  """
  @spec whereis(module(), keyword()) :: pid() | nil
  def whereis(module, opts \\ []) do
    case Registry.lookup(@registry, Kuroneko.Gadget.function_dir(module, opts)) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end

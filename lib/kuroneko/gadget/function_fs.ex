defmodule Kuroneko.Gadget.FunctionFS do
  @moduledoc """
  A USB function written in Elixir: its interfaces and endpoints as data,
  its control requests and transfers as events, on the kernel's FunctionFS.

      defmodule Loopback do
        use Kuroneko.Gadget.FunctionFS
        alias Kuroneko.Gadget.FunctionFS

        @impl FunctionFS
        def interfaces(_settings),
          do: [[name: "Loopback", endpoints: [{:in, :bulk}, {:out, :bulk}]]]

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

        def handle_event({:setup, %{type: :vendor, direction: :in, length: length}}, state) do
          FunctionFS.answer(self(), binary_part("Kuroneko", 0, min(length, 8)))
          {:noreply, state}
        end

        def handle_event(event, state), do: super(event, state)
      end

      Kuroneko.Gadget.configure([:keyboard, :mouse, Loopback])

  A module that uses this one is a function of `Kuroneko.Gadget.Function`,
  of the type `"ffs"`: `Loopback`, or `{Loopback, name: "loop2", ...}` with
  its settings, the options besides `:name`. Its endpoints, numbered from 1
  in the order of `c:interfaces/1`, count against the controller's.

  Each instance runs in a process of its own, which calls the module's
  callbacks: `c:init/1` with the settings, then `c:handle_event/2` with what
  happens on the bus and to the transfers asked for, and `c:handle_info/2`
  with other messages. `write/3`, `read/3`, `answer/2` and `stall/1` ask the
  process for transfers, from the callbacks (`self()`) or from anywhere
  (`whereis/2`); their results come back as events.

  The process starts when the gadget readies the function, before it
  connects, and stops when the function is removed. An exception in a
  callback is logged and the function goes on. When the process goes for
  another reason, the function stays on the bus without its endpoints until
  the functions are configured again.

  `layout/1` and `events/1` are the descriptors and events themselves, for
  programs of your own.
  """
  import Bitwise

  require Logger

  alias __MODULE__, as: FunctionFS
  alias Kuroneko.Gadget.Function, as: GadgetFunction
  alias Kuroneko.Gadget.FunctionFS.Server

  @descriptors_magic_v2 3
  @strings_magic 2
  @has_fs_desc 1
  @has_hs_desc 2
  @english 0x0409

  @types %{isochronous: 1, bulk: 2, interrupt: 3}
  @syncs %{none: 0, async: 1, adaptive: 2, sync: 3}
  @intervals [1, 2, 4, 8, 16, 32, 64, 128]
  @events %{0 => :bind, 1 => :unbind, 2 => :enable, 3 => :disable, 5 => :suspend, 6 => :resume}
  @registry Kuroneko.Gadget.FunctionFS.Registry
  @supervisor Kuroneko.Gadget.FunctionFS.Supervisor

  @typedoc """
  An endpoint: its direction and transfer type, with options:

    * `:max_packet` - the largest packet, in bytes: for bulk endpoints at
      full speed (8, 16, 32 or 64, 64 by default; high speed has 512), for
      the others at both speeds (up to 64 for interrupt endpoints at full
      speed, 1023 for isochronous ones), 64 by default for interrupt
      endpoints and 1023 for isochronous ones
    * `:interval` - how often an interrupt or isochronous endpoint is
      served, in milliseconds: 1, 2, 4... up to 128, 1 by default
    * `:sync` - an isochronous endpoint's synchronization: `:none`,
      `:async` (the default), `:adaptive` or `:sync`
    * `:extra` - class-specific descriptors after the endpoint's, binaries
  """
  @type endpoint() ::
          {:in | :out, :bulk | :interrupt | :isochronous}
          | {:in | :out, :bulk | :interrupt | :isochronous, keyword()}

  @typedoc """
  An interface: `:class`, `:subclass` and `:protocol` (0xFF, 0 and 0 by
  default, vendor-specific), `:name`, which the host may show, `:extra`,
  class-specific descriptors between the interface's and its endpoints'
  (binaries), and its `:endpoints`.
  """
  @type interface() :: keyword()

  @typedoc "An endpoint's number and file, see `layout/1`."
  @type endpoint_file() :: %{
          number: pos_integer(),
          file: String.t(),
          interface: non_neg_integer(),
          direction: :in | :out,
          type: :bulk | :interrupt | :isochronous
        }

  @typedoc "A control request to the function, from a `{:setup, request}` event."
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

    * `:bind`, `:unbind` - the gadget takes the function on and off the bus
    * `:enable`, `:disable` - the host starts and stops using it: its
      endpoints carry data in between
    * `:suspend`, `:resume` - the bus sleeps and wakes
    * `{:setup, request}` - a control request to the function, which waits
      for `answer/2` or `stall/1`, two seconds at most, then is stalled
    * `{:control_data, data}` - the data an OUT request carried, read by
      `answer/2`
    * `{:control_error, reason}` - an answer or stall the host did not take
    * `{:data, endpoint, data}` - what a `read/3` got
    * `{:written, endpoint, bytes}` - a `write/3` done
    * `{:error, endpoint, reason}` - a read or write that failed, such as
      `:eshutdown` when the host disables the function
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
          | {:error, non_neg_integer(), term()}

  @doc "The function's interfaces for these settings."
  @callback interfaces(settings :: term()) :: [interface()]

  @doc "The process's state at start, from the settings; the settings by default."
  @callback init(settings :: term()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Handles an event; by default control requests are stalled and the rest ignored."
  @callback handle_event(event(), state :: term()) :: {:noreply, state :: term()}

  @doc "Handles another message to the process."
  @callback handle_info(message :: term(), state :: term()) :: {:noreply, state :: term()}

  @optional_callbacks init: 1, handle_event: 2, handle_info: 2

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour GadgetFunction
      @behaviour FunctionFS

      @impl GadgetFunction
      def type, do: "ffs"

      @impl GadgetFunction
      def default_name, do: FunctionFS.default_name(__MODULE__)

      @impl GadgetFunction
      def settings(opts), do: FunctionFS.settings(__MODULE__, opts)

      @impl GadgetFunction
      def endpoints(settings), do: FunctionFS.endpoints(interfaces(settings))

      @impl GadgetFunction
      def setup(_dir, _settings), do: :ok

      @impl GadgetFunction
      def ready(dir, settings), do: FunctionFS.ready(__MODULE__, dir, settings)

      @impl GadgetFunction
      def teardown(dir, _settings), do: FunctionFS.teardown(dir)

      @impl FunctionFS
      def init(settings), do: {:ok, settings}

      @impl FunctionFS
      def handle_event(event, state), do: FunctionFS.default_event(event, state)

      defoverridable default_name: 0, settings: 1, init: 1, handle_event: 2
    end
  end

  @doc """
  Writes data to an IN endpoint, for the host to read: `{:written,
  endpoint, bytes}` follows. An empty binary is a packet of zero length.
  """
  @spec write(GenServer.server(), pos_integer(), binary()) :: :ok
  def write(server, endpoint, data), do: GenServer.cast(server, {:write, endpoint, data})

  @doc """
  Reads up to `size` bytes, a multiple of the packet size best, from an OUT
  endpoint: `{:data, endpoint, data}` follows when the host sends them.
  """
  @spec read(GenServer.server(), pos_integer(), non_neg_integer()) :: :ok
  def read(server, endpoint, size), do: GenServer.cast(server, {:read, endpoint, size})

  @doc """
  Answers the control request waiting: an IN request with the data to send,
  an OUT one by reading the data it carries, which comes as
  `{:control_data, data}`.
  """
  @spec answer(GenServer.server(), binary()) :: :ok
  def answer(server, data \\ <<>>), do: GenServer.cast(server, {:answer, data})

  @doc "Refuses the control request waiting."
  @spec stall(GenServer.server()) :: :ok
  def stall(server), do: GenServer.cast(server, :stall)

  @doc """
  The process of a module's function: the default instance, or the one
  `:name` names. Takes the `:gadget` option.
  """
  @spec whereis(module(), keyword()) :: pid() | nil
  def whereis(module, opts \\ []) do
    case Registry.lookup(@registry, Kuroneko.Gadget.function_dir(module, opts)) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  The descriptors and strings of these interfaces, to write to `ep0` in
  this order, and their endpoints, numbered in order from 1, with their
  files.

      Kuroneko.Gadget.FunctionFS.layout([
        [class: 0xFF, name: "Loopback", endpoints: [{:in, :bulk}, {:out, :bulk}]]
      ])
      #=> {:ok, %{descriptors: <<3, 0, 0, 0, ...>>, strings: <<2, 0, 0, 0, ...>>,
      #=>         endpoints: [%{number: 1, file: "ep1", interface: 0, direction: :in, type: :bulk},
      #=>                     %{number: 2, file: "ep2", interface: 0, direction: :out, type: :bulk}]}}
  """
  @spec layout([interface()]) ::
          {:ok, %{descriptors: binary(), strings: binary(), endpoints: [endpoint_file()]}}
          | {:error, term()}
  def layout(interfaces) when is_list(interfaces) and interfaces != [] do
    with {:ok, parsed} <- collect(Enum.with_index(interfaces), &interface/1) do
      names = parsed |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      numbered = number_endpoints(parsed)

      files =
        for interface <- numbered, endpoint <- interface.endpoints do
          %{
            number: endpoint.number,
            file: "ep#{endpoint.number}",
            interface: interface.number,
            direction: endpoint.direction,
            type: endpoint.type
          }
        end

      {:ok,
       %{descriptors: descriptors(numbered, names), strings: strings(names), endpoints: files}}
    end
  end

  def layout(other), do: {:error, {:invalid_interfaces, other}}

  @doc """
  The events in what a read of `ep0` gave, 12 bytes each.
  """
  @spec events(binary()) :: [event()]
  def events(<<setup::binary-size(8), type, _pad::binary-size(3), rest::binary>>),
    do: [event(type, setup) | events(rest)]

  def events(_rest), do: []

  @doc false
  @spec default_name(module()) :: String.t()
  def default_name(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  @doc false
  @spec settings(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def settings(module, opts) do
    settings = Map.new(opts)

    with {:ok, _layout} <- layout(module.interfaces(settings)), do: {:ok, settings}
  end

  @doc false
  @spec endpoints([interface()]) :: {non_neg_integer(), non_neg_integer()}
  def endpoints(interfaces) do
    {:ok, %{endpoints: endpoints}} = layout(interfaces)

    {Enum.count(endpoints, &(&1.direction == :in)),
     Enum.count(endpoints, &(&1.direction == :out))}
  end

  @doc false
  @spec default_event(event(), term()) :: {:noreply, term()}
  def default_event({:setup, _request}, state) do
    stall(self())
    {:noreply, state}
  end

  def default_event(_event, state), do: {:noreply, state}

  @doc false
  @spec ready(module(), Path.t(), term()) :: :ok | {:error, term()}
  def ready(module, dir, settings) do
    with [] <- Registry.lookup(@registry, dir),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(@supervisor, {Server, {module, dir, settings}}) do
      :ok
    else
      [{_pid, _value}] -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec teardown(Path.t()) :: :ok | {:error, term()}
  def teardown(dir) do
    :ok = stop_server(dir)
    umount(mount_dir(dir))
  end

  defp stop_server(dir) do
    with [{pid, _value}] <- Registry.lookup(@registry, dir),
         :ok <- DynamicSupervisor.terminate_child(@supervisor, pid) do
      :ok
    else
      _none_or_gone -> :ok
    end
  end

  # The function's FunctionFS: the kernel names it after the instance, and
  # each instance's name is the system's only one.
  @doc false
  @spec mount_dir(Path.t()) :: Path.t()
  def mount_dir(dir) do
    "ffs." <> instance = Path.basename(dir)
    "/dev/ffs-" <> instance
  end

  # Closing ep0 while the gadget is on the bus would take the whole gadget
  # off: no_disconnect leaves the others working.
  @doc false
  @spec mount(Path.t()) :: :ok | {:error, term()}
  def mount(dir) do
    target = mount_dir(dir)
    "ffs." <> instance = Path.basename(dir)

    if mounted?(target) do
      :ok
    else
      with :ok <- File.mkdir_p(target),
           {_output, 0} <-
             System.cmd("mount", ["-t", "functionfs", "-o", "no_disconnect=1", instance, target],
               stderr_to_stdout: true
             ) do
        :ok
      else
        {:error, reason} -> {:error, reason}
        {output, status} -> {:error, {:mount, status, String.trim(output)}}
      end
    end
  end

  defp umount(target) do
    if mounted?(target) do
      case umount_retrying(target, 20) do
        :ok ->
          _ = File.rmdir(target)
          :ok

        error ->
          error
      end
    else
      _ = File.rmdir(target)
      :ok
    end
  end

  # The program's files close as it exits, a moment after it is told to.
  defp umount_retrying(target, tries) do
    case System.cmd("umount", [target], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} when tries > 1 ->
        Logger.debug("kuroneko_gadget: umount #{target}: #{String.trim(output)} (#{status})")
        Process.sleep(100)
        umount_retrying(target, tries - 1)

      {output, status} ->
        {:error, {:umount, status, String.trim(output)}}
    end
  end

  defp mounted?(target) do
    case File.read("/proc/mounts") do
      {:ok, mounts} ->
        mounts
        |> String.split("\n", trim: true)
        |> Enum.any?(&match?([_source, ^target | _rest], String.split(&1, " ")))

      {:error, _reason} ->
        false
    end
  end

  @doc false
  @spec program() :: {:ok, Path.t()} | {:error, :no_program}
  def program do
    path = Application.app_dir(:kuroneko_gadget, ["priv", "kuroneko_ffs"])
    if File.exists?(path), do: {:ok, path}, else: {:error, :no_program}
  end

  defp event(4, <<request_type, request, value::little-16, index::little-16, length::little-16>>) do
    {:setup,
     %{
       direction: if((request_type &&& 0x80) == 0, do: :out, else: :in),
       type: Enum.at([:standard, :class, :vendor, :reserved], request_type >>> 5 &&& 3),
       recipient:
         Map.get(%{0 => :device, 1 => :interface, 2 => :endpoint}, request_type &&& 0x1F, :other),
       request: request,
       value: value,
       index: index,
       length: length
     }}
  end

  defp event(type, _setup), do: Map.get(@events, type, {:unknown, type})

  defp interface({opts, number}) do
    known = [:class, :subclass, :protocol, :name, :extra, :endpoints]

    with true <- Keyword.keyword?(opts) || {:error, {:invalid_interface, opts}},
         [] <- Keyword.keys(opts) -- known,
         {:ok, codes} <- codes(opts),
         {:ok, name} <- name(opts[:name]),
         {:ok, extra} <- extra(Keyword.get(opts, :extra, [])),
         {:ok, endpoints} <- collect(Keyword.get(opts, :endpoints, []), &endpoint/1) do
      {:ok, Map.merge(codes, %{number: number, name: name, extra: extra, endpoints: endpoints})}
    else
      [_ | _] = unknown -> {:error, {:unknown_options, :interface, unknown}}
      error -> error
    end
  end

  defp codes(opts) do
    codes = %{
      class: Keyword.get(opts, :class, 0xFF),
      subclass: Keyword.get(opts, :subclass, 0),
      protocol: Keyword.get(opts, :protocol, 0)
    }

    case Enum.find(codes, fn {_key, value} -> value not in 0..255 end) do
      nil -> {:ok, codes}
      {key, value} -> {:error, {:"invalid_#{key}", value}}
    end
  end

  defp name(nil), do: {:ok, nil}

  defp name(name) when is_binary(name) do
    if String.valid?(name) and not String.contains?(name, <<0>>) and byte_size(name) <= 126,
      do: {:ok, name},
      else: {:error, {:invalid_name, name}}
  end

  defp name(name), do: {:error, {:invalid_name, name}}

  # Descriptors, each starting with its length: as many as they hold.
  defp extra(descriptors) when is_list(descriptors) do
    collect(descriptors, fn binary ->
      case split_descriptors(binary) do
        {:ok, split} -> {:ok, split}
        :error -> {:error, {:invalid_descriptor, binary}}
      end
    end)
    |> case do
      {:ok, split} -> {:ok, List.flatten(split)}
      error -> error
    end
  end

  defp extra(other), do: {:error, {:invalid_descriptor, other}}

  defp split_descriptors(<<>>), do: {:ok, []}

  defp split_descriptors(<<length, _type, _rest::binary>> = binary)
       when length >= 2 and byte_size(binary) >= length do
    <<descriptor::binary-size(^length), rest::binary>> = binary

    with {:ok, others} <- split_descriptors(rest), do: {:ok, [descriptor | others]}
  end

  defp split_descriptors(_binary), do: :error

  defp endpoint({direction, type}) when direction in [:in, :out] and is_map_key(@types, type),
    do: endpoint({direction, type, []})

  defp endpoint({direction, type, opts} = spec)
       when direction in [:in, :out] and is_map_key(@types, type) and is_list(opts) do
    known = [:max_packet, :interval, :sync, :extra]

    endpoint = %{
      direction: direction,
      type: type,
      max_packet: Keyword.get(opts, :max_packet, default_packet(type)),
      interval: Keyword.get(opts, :interval, 1),
      sync: Keyword.get(opts, :sync, :async)
    }

    cond do
      Keyword.keys(opts) -- known != [] ->
        {:error, {:unknown_options, spec, Keyword.keys(opts) -- known}}

      not valid_packet?(type, endpoint.max_packet) ->
        {:error, {:invalid_max_packet, spec}}

      endpoint.interval not in @intervals ->
        {:error, {:invalid_interval, spec}}

      not is_map_key(@syncs, endpoint.sync) ->
        {:error, {:invalid_sync, spec}}

      true ->
        with {:ok, extra} <- extra(Keyword.get(opts, :extra, [])),
             do: {:ok, Map.put(endpoint, :extra, extra)}
    end
  end

  defp endpoint(other), do: {:error, {:invalid_endpoint, other}}

  defp default_packet(:bulk), do: 64
  defp default_packet(:interrupt), do: 64
  defp default_packet(:isochronous), do: 1023

  defp valid_packet?(:bulk, size), do: size in [8, 16, 32, 64]
  defp valid_packet?(:interrupt, size), do: is_integer(size) and size in 1..64
  defp valid_packet?(:isochronous, size), do: is_integer(size) and size in 1..1023

  # Endpoints in order from 1, each with a number of its own: their files.
  defp number_endpoints(interfaces) do
    {numbered, _next} =
      Enum.map_reduce(interfaces, 1, fn interface, next ->
        endpoints =
          interface.endpoints
          |> Enum.with_index(next)
          |> Enum.map(fn {e, n} -> Map.put(e, :number, n) end)

        {%{interface | endpoints: endpoints}, next + length(endpoints)}
      end)

    numbered
  end

  defp descriptors(interfaces, names) do
    full = Enum.flat_map(interfaces, &interface_descriptors(&1, names, :full))
    high = Enum.flat_map(interfaces, &interface_descriptors(&1, names, :high))
    body = IO.iodata_to_binary([full, high])

    <<@descriptors_magic_v2::little-32, byte_size(body) + 20::little-32,
      @has_fs_desc ||| @has_hs_desc::little-32, length(full)::little-32, length(high)::little-32,
      body::binary>>
  end

  defp interface_descriptors(interface, names, speed) do
    string =
      case Enum.find_index(names, &(&1 == interface.name)) do
        nil -> 0
        index -> index + 1
      end

    [
      <<9, 4, interface.number, 0, length(interface.endpoints), interface.class,
        interface.subclass, interface.protocol, string>>
    ] ++
      interface.extra ++
      Enum.flat_map(interface.endpoints, &[endpoint_descriptor(&1, speed) | &1.extra])
  end

  defp endpoint_descriptor(endpoint, speed) do
    address = if endpoint.direction == :in, do: 0x80 ||| endpoint.number, else: endpoint.number

    attributes =
      @types[endpoint.type] |||
        if(endpoint.type == :isochronous, do: @syncs[endpoint.sync] <<< 2, else: 0)

    <<7, 5, address, attributes, packet(endpoint, speed)::little-16, interval(endpoint, speed)>>
  end

  defp packet(%{type: :bulk}, :high), do: 512
  defp packet(endpoint, _speed), do: endpoint.max_packet

  # Full speed counts interrupt intervals in frames of 1 ms, isochronous
  # ones as 2^(n - 1) frames; high speed both as 2^(n - 1) microframes.
  defp interval(%{type: :bulk}, _speed), do: 0
  defp interval(%{type: :interrupt, interval: ms}, :full), do: ms
  defp interval(%{interval: ms}, :full), do: log2(ms) + 1
  defp interval(%{interval: ms}, :high), do: log2(ms * 8) + 1

  defp log2(1), do: 0
  defp log2(n), do: 1 + log2(n >>> 1)

  defp strings([]), do: <<@strings_magic::little-32, 16::little-32, 0::little-32, 0::little-32>>

  defp strings(names) do
    table = [<<@english::little-16>> | Enum.map(names, &[&1, 0])]
    body = IO.iodata_to_binary(table)

    <<@strings_magic::little-32, byte_size(body) + 16::little-32, length(names)::little-32,
      1::little-32, body::binary>>
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end
end

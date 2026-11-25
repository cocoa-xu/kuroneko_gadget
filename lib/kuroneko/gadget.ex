defmodule Kuroneko.Gadget do
  @configfs "/sys/kernel/config/usb_gadget"
  @udc_class "/sys/class/udc"

  @moduledoc """
  The USB side of a KVM: the functions the target computer sees, on a USB
  gadget in configfs.

  The system sets the gadget up at boot, often with a network function,
  and binds it to the device controller. This process adds functions to it
  and changes them:

      Kuroneko.Gadget.configure([:keyboard, :mouse, {:storage, luns: 2}])

  ## Functions

  Linux sorts gadget functions by driver, and so does this library: each
  driver is a module of `Kuroneko.Gadget.Function`, whose instances go in
  the functions as `{Module, name: "x", ...}` with the module's options.

    * `Kuroneko.Gadget.HID` - keyboards, mice, game controllers, by their
      report descriptors
    * `Kuroneko.Gadget.MassStorage` - drives that hold image files
    * `Kuroneko.Gadget.NCM` - a network adapter
    * `Kuroneko.Gadget.UAC2` - a sound card
    * `Kuroneko.Gadget.ACM` - a serial port
    * `Kuroneko.Gadget.FunctionFS` - a function written in Elixir

  A KVM's functions have shorthands, instances of these:

    * `:keyboard` - a boot keyboard
    * `:mouse` - the absolute pointer: `{:mouse, mode: mode}` makes it an
      `:absolute` mouse (the default), a `:stylus` (a pen, for Android and
      iPadOS) or a `:touch` screen
    * `:relative_mouse` - a boot mouse that moves by steps, which BIOS
      setups and games take
    * `:storage` - drives, one by default: `{:storage, luns: 3}` has three
    * `:network` - the USB network, see "The network" below
    * `:microphone` and `:speaker` - the two directions of a sound card,
      with its format: `{:microphone, channels: 1, rates: [44_100, 48_000]}`

  `Kuroneko.Gadget.Input` types and points with the keyboard and mice, and
  `Kuroneko.Gadget.MassStorage` puts images in the drives.

  Each function has a name, its kind's by default (`"keyboard"`, `"mouse"`,
  `"relative_mouse"`, `"disk"`, `"usb0"`, `"audio"`), and there may be
  several of a kind, each with a name of its own: `[:storage, {:storage,
  name: "boot"}]` are two storage devices. Names take letters, digits, `_`
  and `-`.

  Each function takes endpoints of the device controller, which has few
  (`endpoints/1`). With the `:endpoints` option the functions must fit, or
  `configure/2` tells how many they need and how many there are.

  Changing the functions takes the gadget off the bus and puts it back: the
  target sees its devices unplugged and plugged in. With the functions
  already there nothing happens, so starting the process again is cheap. A
  change the system refuses leaves the functions as they were, and so does
  an exception in a function module's `setup`, `update`, `ready` or
  `teardown`.

  ## The network

  A network function the system set up has two MAC addresses: the device's,
  of its interface, and the target's, of the network adapter the target
  sees. `network/1` tells them, and `set_network_addresses/2` changes them
  and, with the `:persist` function of the `:network` option, keeps them
  for the next boots.

  The functions take the network functions in hand only when they include
  a `:network`, or always with `manage_networks: true`: then `[:network,
  {:network, name: "usb1"}]` keeps the system's network and adds a second,
  and a list without the system's network removes it.

  ## Options

    * `:functions` - the functions to have, none by default. Or
      `{module, function, args}` that returns them, called each time the
      process starts: a restart by its supervisor then sets up those saved
      last, a user's settings say
    * `:name` - the name to register, `Kuroneko.Gadget` by default
    * `:gadget` - the gadget's configfs directory, `default_gadget/0` by
      default
    * `:udc_class` - where the device controllers are, `#{@udc_class}` by
      default
    * `:replug_ms` - how long `replug/2` keeps the gadget off the bus, 1500
      by default
    * `:endpoints` - the controller's endpoints besides endpoint 0, such as
      `%{in: 7, out: 7}`; not checked without it
    * `:max_packet` - the largest packets the controller takes for the
      `:microphone` and the `:speaker`, `%{microphone: 1024, speaker: 1024}`
      by default, the most high speed carries
    * `:names` - what the target calls the functions: `:audio` (the sound
      card), `:microphone`, `:speaker`, and `:storage` (the drives) as
      `{vendor, product, revision}`; the kernel's names by default
    * `:manage_networks` - whether the network functions are always this
      process's, so that functions without one remove them all; by default
      only when the functions include one
    * `:network` - the system's network function:
      * `:function` - its configfs directory, `"ncm.usb0"` by default
      * `:default_addresses` - the addresses `:default` stands for in
        `set_network_addresses/2`, and those the system's network takes
        when it is created anew
      * `:persist` - a function that keeps addresses for the next boots: it
        takes those `set_network_addresses/2` was given, as a map with
        `:device_address`, `:host_address` or both, each an address or
        `:default`, and returns `:ok` or `{:error, reason}`

  Board libraries give these for their boards, such as
  `NanoKVMGo.USB.gadget_options/1` for the Sipeed NanoKVM-Go.
  """

  use GenServer

  require Logger

  import Kuroneko.Gadget.Kinds, only: [is_kind: 1]

  alias Kuroneko.Gadget.Configfs
  alias Kuroneko.Gadget.Kinds
  alias Kuroneko.Gadget.MAC
  alias Kuroneko.Gadget.NCM

  @config "configs/c.1"
  @bus_powered_with_remote_wakeup "0xa0"
  @configure_timeout 30_000
  @states %{
    "not attached" => :not_attached,
    "attached" => :attached,
    "powered" => :powered,
    "reconnecting" => :reconnecting,
    "unauthenticated" => :unauthenticated,
    "default" => :default,
    "addressed" => :addressed,
    "configured" => :configured,
    "suspended" => :suspended
  }
  @speeds %{
    "low-speed" => :low_speed,
    "full-speed" => :full_speed,
    "high-speed" => :high_speed,
    "super-speed" => :super_speed,
    "super-speed-plus" => :super_speed_plus
  }

  @typedoc "A built-in kind of function, a shorthand for an instance of a module."
  @type kind() ::
          :keyboard
          | :mouse
          | :relative_mouse
          | :storage
          | :network
          | :microphone
          | :speaker
          | :audio

  @typedoc "A function to have: a kind or a module, alone or with options, `:name` among them."
  @type function_spec() :: kind() | {kind(), keyword()} | module() | {module(), keyword()}

  @typedoc """
  A function on the gadget: its kind and name, and what the kind tells. A
  module's function has its settings; a network, its interface and
  addresses (see `instances/1`).
  """
  @type instance() :: %{
          required(:kind) => kind() | module(),
          required(:name) => String.t(),
          optional(atom()) => term()
        }

  @type endpoints() :: %{in: non_neg_integer(), out: non_neg_integer()}

  @typedoc "A configfs or sysfs operation that failed, and the path it failed on."
  @type configfs_error() :: {:configfs, Path.t(), File.posix()}

  @typedoc "The state of the USB connection, see `connection/1`."
  @type connection_state() ::
          :not_attached
          | :attached
          | :powered
          | :reconnecting
          | :unauthenticated
          | :default
          | :addressed
          | :configured
          | :suspended
          | :unknown

  @type speed() ::
          :low_speed | :full_speed | :high_speed | :super_speed | :super_speed_plus | :unknown

  @typedoc "The USB network, see `network/1`."
  @type network() :: %{
          interface: String.t() | nil,
          device_address: NCM.address(),
          host_address: NCM.address(),
          default_addresses: NCM.addresses() | nil
        }

  @typedoc "What `set_network_addresses/2` takes."
  @type network_setting() ::
          {:device_address, NCM.address() | :default}
          | {:host_address, NCM.address() | :default}
          | {:persist, boolean()}

  @typedoc "Addresses to keep for the next boots, see the `:network` option."
  @type kept_addresses() :: %{
          optional(:device_address | :host_address) => NCM.address() | :default
        }

  @type option() ::
          {:functions, [function_spec()] | {module(), atom(), [term()]}}
          | {:name, GenServer.name() | nil}
          | {:gadget, Path.t()}
          | {:udc_class, Path.t()}
          | {:replug_ms, non_neg_integer()}
          | {:endpoints, endpoints()}
          | {:max_packet, %{optional(:microphone | :speaker) => pos_integer()}}
          | {:names, keyword()}
          | {:manage_networks, boolean()}
          | {:network, keyword()}

  @doc """
  Starts the process and sets up the functions. See the module documentation
  for the options; invalid ones raise `ArgumentError`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = check_options!(opts)
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sets up these functions and removes the others of this process. Network
  functions are among them when the list has a `:network`; without one, the
  network the system set up stays as it is.

      Kuroneko.Gadget.configure([:keyboard, :mouse, {:storage, luns: 3}])
      Kuroneko.Gadget.configure([:keyboard, :storage, {:storage, name: "boot"}])
      Kuroneko.Gadget.configure([:network, {:network, name: "usb1"}, :keyboard])
  """
  @spec configure(GenServer.server(), [function_spec()]) :: :ok | {:error, term()}
  def configure(server \\ __MODULE__, functions) when is_list(functions),
    do: GenServer.call(server, {:configure, functions}, @configure_timeout)

  @doc """
  Checks functions without setting them up: whether `configure/2` would take
  them from a process started with these options (`:max_packet`, `:names`
  and `:endpoints` count; `configure/2` also counts the network functions
  it leaves alone).

      iex> Kuroneko.Gadget.validate([:keyboard, {:microphone, channels: 1, rates: [44_100]}])
      :ok
      iex> Kuroneko.Gadget.validate([{:speaker, sample_bits: 20}])
      {:error, {:invalid_sample_bits, :speaker, 20}}
      iex> Kuroneko.Gadget.validate([{:storage, luns: 17}])
      {:error, {:invalid_luns, 17}}
      iex> Kuroneko.Gadget.validate([:storage, {:storage, name: "boot"}, :microphone],
      ...>   endpoints: %{in: 2, out: 2})
      {:error, {:not_enough_endpoints, %{need: %{in: 3, out: 2}, have: %{in: 2, out: 2}}}}
  """
  @spec validate([function_spec()], [option()]) :: :ok | {:error, term()}
  def validate(functions, opts \\ []) when is_list(functions) do
    opts = check_options!(opts)

    with {:ok, instances} <- normalize(functions, defaults(opts)),
         do: check_endpoints(instances, opts[:endpoints])
  end

  @doc """
  The endpoints functions take:

      iex> Kuroneko.Gadget.endpoints([:keyboard, :mouse, {:storage, luns: 4}, :network])
      {:ok, %{in: 5, out: 2}}
      iex> Kuroneko.Gadget.endpoints([:keyboard, Kuroneko.Gadget.ACM])
      {:ok, %{in: 3, out: 1}}
  """
  @spec endpoints([function_spec()]) :: {:ok, endpoints()} | {:error, term()}
  def endpoints(functions) when is_list(functions) do
    with {:ok, instances} <- normalize(functions, defaults([])),
         do: {:ok, count_endpoints(instances)}
  end

  @doc """
  The kinds of the functions of this process on the gadget, each once: a
  sound card as its `:microphone`, its `:speaker` or both, a module's
  function as its module.
  """
  @spec functions(GenServer.server()) :: [kind() | module()]
  def functions(server \\ __MODULE__), do: GenServer.call(server, :functions)

  @doc """
  Sends the caller `{Kuroneko.Gadget, {:functions, kinds}}` each time the
  kinds of the functions change, as `functions/1` gives them, until it
  unsubscribes or exits. Returns the kinds now. The message comes before
  the reply to the `configure/2` that changed them.
  """
  @spec subscribe(GenServer.server()) :: {:ok, [kind() | module()]}
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, :subscribe)

  @doc "Stops the messages of `subscribe/1`."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, :unsubscribe)

  @doc """
  The functions on the gadget that this process knows:

      [%{kind: :network, name: "usb0", interface: "usb0",
         device_address: "9e:9f:51:11:f7:b2", host_address: "7a:78:1f:1f:1d:dd"},
       %{kind: :keyboard, name: "keyboard"},
       %{kind: :mouse, name: "mouse", mode: :absolute},
       %{kind: :storage, name: "disk", luns: 2},
       %{kind: :audio, name: "audio", microphone: %{channels: 2, rates: [48_000], sample_bits: 16}, speaker: nil},
       %{kind: Kuroneko.Gadget.ACM, name: "serial", settings: %{}}]

  A network's interface is `nil` before the gadget first connects.
  """
  @spec instances(GenServer.server()) :: [instance()]
  def instances(server \\ __MODULE__), do: GenServer.call(server, :instances)

  @doc """
  The endpoints the gadget's functions take now, the network functions
  this process leaves alone among them, and those the controller has (the
  `:endpoints` option, `nil` without it):

      Kuroneko.Gadget.endpoints_in_use()
      #=> %{in: 7, out: 3, have: %{in: 7, out: 7}}
  """
  @spec endpoints_in_use(GenServer.server()) :: %{
          in: non_neg_integer(),
          out: non_neg_integer(),
          have: endpoints() | nil
        }
  def endpoints_in_use(server \\ __MODULE__), do: GenServer.call(server, :endpoints_in_use)

  @doc """
  Takes the gadget off the USB bus and puts it back, so that the target
  finds its devices anew, as if they had been unplugged. A computer reads
  what kind of drive a mass storage logical unit is only then. A gadget on
  no device controller stays as it is. `{:error, :noproc}` without the
  process.
  """
  @spec replug(GenServer.server()) :: :ok | {:error, term()}
  def replug(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> {:error, :noproc}
      pid -> GenServer.call(pid, :replug, 30_000)
    end
  end

  @doc """
  The USB connection to the target: the state the target has put the
  device in, the speed and the device controller.

    * `:configured` - the target uses the functions
    * `:suspended` - the target sleeps, or has suspended the port
    * `:not_attached` - no computer at the other end of the cable
    * `:attached`, `:powered`, `:default`, `:addressed` - on the way to
      `:configured`

      Kuroneko.Gadget.connection()
      #=> {:ok, %{state: :configured, speed: :high_speed, controller: "8000000.usb"}}

  `{:error, :no_udc}` without a controller bound to the gadget. Takes the
  `:gadget` and `:udc_class` options.
  """
  @spec connection(keyword()) ::
          {:ok, %{state: connection_state(), speed: speed(), controller: String.t()}}
          | {:error, term()}
  def connection(opts \\ []) do
    opts = Keyword.validate!(opts, [:gadget, udc_class: @udc_class])

    with {:ok, udc} <- bound_udc(opts[:gadget] || default_gadget()),
         dir = Path.join(opts[:udc_class], udc),
         {:ok, state} <- Configfs.read_text(Path.join(dir, "state")) do
      speed =
        case Configfs.read_text(Path.join(dir, "current_speed")) do
          {:ok, speed} -> Map.get(@speeds, speed, :unknown)
          {:error, _reason} -> :unknown
        end

      {:ok, %{state: Map.get(@states, state, :unknown), speed: speed, controller: udc}}
    else
      :unbound -> {:error, :no_udc}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The USB network the system set up (the `:network` option's function): the
  device's interface and its address, the address of the target's end, and
  the addresses `:default` stands for (`nil` without them).

      Kuroneko.Gadget.network()
      #=> {:ok, %{interface: "usb0", device_address: "9e:9f:51:11:f7:b2",
      #=>         host_address: "02:12:34:56:78:9a", default_addresses: nil}}
  """
  @spec network(GenServer.server()) :: {:ok, network()} | {:error, term()}
  def network(server \\ __MODULE__), do: GenServer.call(server, :network)

  @doc """
  Gives the USB network other addresses, MAC addresses or `:default`:

    * `:device_address` - the device's
    * `:host_address` - the target's

  One left out stays as it is. The gadget leaves the bus and comes back, and
  the device's interface goes away and comes back with its address. The
  `:network` option's `:persist` function keeps the addresses for the next
  boots, unless `persist: false`.

      Kuroneko.Gadget.set_network_addresses(host_address: "02:12:34:56:78:9a")
      Kuroneko.Gadget.set_network_addresses(device_address: :default, host_address: :default)

  Refused: an address that is not one (`{:invalid_address, key, value}`)
  or is a multicast address (`{:multicast_address, key, value}`), and the
  same address at both ends (`:same_addresses`). Addresses set but not kept
  give `{:error, {:not_kept, reason}}`.
  """
  @spec set_network_addresses(GenServer.server(), [network_setting()]) :: :ok | {:error, term()}
  def set_network_addresses(server \\ __MODULE__, settings) when is_list(settings),
    do: GenServer.call(server, {:set_network_addresses, settings}, 15_000)

  @doc "Checks addresses as `set_network_addresses/2` would, without setting them."
  @spec validate_network_addresses(GenServer.server(), [network_setting()]) ::
          :ok | {:error, term()}
  def validate_network_addresses(server \\ __MODULE__, settings) when is_list(settings),
    do: GenServer.call(server, {:validate_network_addresses, settings})

  @doc """
  The gadget the functions go on when none is given: the only gadget in the
  `configfs` gadget directory, `#{@configfs}` by default, else one named
  `kuroneko` there.
  """
  @spec default_gadget(Path.t()) :: Path.t()
  def default_gadget(configfs \\ @configfs) do
    case File.ls(configfs) do
      {:ok, [name]} -> Path.join(configfs, name)
      _none_or_several -> Path.join(configfs, "kuroneko")
    end
  end

  @doc """
  The configfs directory of a function: a kind's, such as `:keyboard`, or a
  module's. Takes `:name`, the kind's or the module's default name without
  it, and `:gadget`.

      Kuroneko.Gadget.function_dir(:storage, name: "boot")
      #=> "/sys/kernel/config/usb_gadget/kuroneko/functions/mass_storage.boot"
  """
  @spec function_dir(kind() | module(), keyword()) :: Path.t()
  def function_dir(function, opts \\ []) do
    opts = Keyword.validate!(opts, [:name, :gadget])

    {module, name} =
      if is_kind(function),
        do: {Kinds.module(function), opts[:name] || Kinds.default_name(function)},
        else: {function, opts[:name] || function.default_name()}

    Path.join([opts[:gadget] || default_gadget(), "functions", "#{module.type()}.#{name}"])
  end

  @impl GenServer
  def init(opts) do
    network = opts[:network]
    functions = initial_functions(opts)

    state = %{
      gadget: opts[:gadget] || default_gadget(),
      udc_class: opts[:udc_class],
      replug_ms: opts[:replug_ms],
      endpoints: opts[:endpoints],
      defaults: defaults(opts),
      manage_networks: opts[:manage_networks],
      network_managed: opts[:manage_networks] or network?(functions),
      network: Map.new(network),
      module_functions: %{},
      subscribers: %{},
      kinds: []
    }

    state =
      case apply_functions(state, functions) do
        {:ok, functions} ->
          %{state | module_functions: functions}

        {:error, reason} ->
          Logger.error("kuroneko_gadget: USB functions not set up: #{inspect(reason)}")
          state
      end

    {:ok, %{state | kinds: kinds_now(state)}}
  end

  @impl GenServer
  def handle_call({:configure, specs}, _from, state) do
    case apply_functions(state, specs) do
      {:ok, functions} ->
        managed = state.manage_networks or network?(specs)
        state = %{state | network_managed: managed, module_functions: functions}
        {:reply, :ok, notify(state)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:functions, _from, state), do: {:reply, kinds_now(state), state}

  def handle_call(:subscribe, {pid, _tag}, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, {:ok, state.kinds}, %{state | subscribers: subscribers}}
  end

  def handle_call(:unsubscribe, {pid, _tag}, state) do
    {monitor, subscribers} = Map.pop(state.subscribers, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:instances, _from, state),
    do: {:reply, state |> present() |> Enum.map(&details(state, &1)), state}

  def handle_call(:endpoints_in_use, _from, state),
    do: {:reply, Map.put(count_endpoints(present(state)), :have, state.endpoints), state}

  def handle_call(:replug, from, state) do
    with {:ok, udc} <- bound_udc(state.gadget),
         :ok <- Configfs.write(soft_connect(state, udc), "disconnect") do
      Process.send_after(self(), {:connect, udc, from}, state.replug_ms)
      {:noreply, state}
    else
      :unbound -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:network, _from, state), do: {:reply, read_network(state), state}

  def handle_call({:validate_network_addresses, settings}, _from, state) do
    reply =
      with {:ok, network} <- read_network(state),
           {:ok, _wanted} <- wanted_addresses(settings, network),
           do: :ok

    {:reply, reply, state}
  end

  def handle_call({:set_network_addresses, settings}, _from, state) do
    reply =
      with {:ok, network} <- read_network(state),
           {:ok, wanted} <- wanted_addresses(settings, network),
           :ok <- readdress(state, Map.take(network, [:device_address, :host_address]), wanted) do
        if Keyword.get(settings, :persist, true), do: persist(state, settings, wanted), else: :ok
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:connect, udc, from}, state) do
    GenServer.reply(from, Configfs.write(soft_connect(state, udc), "connect"))
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  # Sent from the call that changed them, so before its reply.
  defp notify(state) do
    case kinds_now(state) do
      kinds when kinds == state.kinds ->
        state

      kinds ->
        for pid <- Map.keys(state.subscribers), do: send(pid, {__MODULE__, {:functions, kinds}})
        %{state | kinds: kinds}
    end
  end

  defp kinds_now(state) do
    state
    |> present()
    |> managed(state)
    |> Enum.flat_map(&kinds/1)
    |> Enum.uniq()
  end

  # Functions a function returns are checked as the process starts.
  defp initial_functions(opts) do
    case opts[:functions] do
      {module, function, args} ->
        functions = apply(module, function, args)
        check_functions!(functions, opts)
        functions

      functions ->
        functions
    end
  end

  defp check_options!(opts) do
    opts =
      Keyword.validate!(opts,
        functions: [],
        name: __MODULE__,
        gadget: nil,
        udc_class: @udc_class,
        replug_ms: 1500,
        endpoints: nil,
        max_packet: %{},
        names: [],
        manage_networks: false,
        network: []
      )

    check!(
      opts[:endpoints] == nil or
        match?(%{in: i, out: o} when is_integer(i) and is_integer(o), opts[:endpoints]),
      :endpoints,
      opts[:endpoints]
    )

    check!(is_boolean(opts[:manage_networks]), :manage_networks, opts[:manage_networks])
    check!(is_integer(opts[:replug_ms]) and opts[:replug_ms] >= 0, :replug_ms, opts[:replug_ms])
    check!(Enum.all?(opts[:max_packet], &max_packet?/1), :max_packet, opts[:max_packet])

    check!(
      Keyword.keyword?(opts[:names]) and Enum.all?(opts[:names], &name?/1),
      :names,
      opts[:names]
    )

    network =
      Keyword.validate!(opts[:network],
        function: "ncm.usb0",
        default_addresses: nil,
        persist: nil
      )

    check!(
      addresses?(network[:default_addresses]),
      :default_addresses,
      network[:default_addresses]
    )

    check!(
      network[:persist] == nil or is_function(network[:persist], 1),
      :persist,
      network[:persist]
    )

    if not mfa?(opts[:functions]), do: check_functions!(opts[:functions], opts)
    Keyword.put(opts, :network, network)
  end

  defp check_functions!(functions, opts) do
    case normalize(functions, defaults(opts)) do
      {:ok, _instances} ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "invalid USB functions #{inspect(functions)}: #{inspect(reason)}"
    end
  end

  defp mfa?({module, function, args}), do: is_atom(module) and is_atom(function) and is_list(args)
  defp mfa?(_functions), do: false

  defp check!(true, _key, _value), do: :ok

  defp check!(false, key, value),
    do: raise(ArgumentError, "invalid #{inspect(key)}: #{inspect(value)}")

  defp max_packet?({direction, size}),
    do: direction in [:microphone, :speaker] and is_integer(size) and size > 0

  defp name?({key, name}) when key in [:audio, :microphone, :speaker], do: is_binary(name)

  defp name?({:storage, {vendor, product, revision}}),
    do: Enum.all?([vendor, product, revision], &is_binary/1)

  defp name?(_other), do: false

  defp addresses?(nil), do: true

  defp addresses?(%{device_address: device, host_address: host}),
    do: match?({:ok, _}, MAC.parse(device)) and match?({:ok, _}, MAC.parse(host))

  defp addresses?(_other), do: false

  defp defaults(opts) do
    %{
      names: Keyword.get(opts, :names, []),
      max_packet:
        Map.merge(
          %{microphone: 1024, speaker: 1024},
          Map.new(Keyword.get(opts, :max_packet, %{}))
        )
    }
  end

  defp apply_functions(state, specs) do
    with {:ok, wanted} <- normalize(specs, state.defaults),
         :ok <- check_gadget(state.gadget),
         {present, others} =
           Enum.split_with(
             present(state, wanted),
             &(state.manage_networks or network?(specs) or &1.module != NCM)
           ),
         :ok <- check_endpoints(wanted ++ others, state.endpoints),
         :ok <- apply_change(state, present, wanted) do
      {:ok, by_dir(wanted)}
    end
  end

  defp apply_change(state, same, same), do: ready_again(state, same)
  defp apply_change(state, present, wanted), do: change(state, present, wanted)

  # Readying a FunctionFS function anew takes the gadget off the bus.
  defp ready_again(state, instances) do
    before = bound_udc(state.gadget)

    with :ok <- each(instances, &ready(state, &1)) do
      if match?({:ok, _udc}, before) and bound_udc(state.gadget) == :unbound,
        do: bind(state, before),
        else: :ok
    end
  end

  defp change(state, present, wanted) do
    Logger.info("kuroneko_gadget: USB functions #{describe(wanted)}, reconnecting the gadget")
    udc = bound_udc(state.gadget)

    case switch(state, udc, present, wanted) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "kuroneko_gadget: USB functions #{describe(wanted)} refused: #{inspect(reason)}"
        )

        go_back(state, udc, present, wanted)
        {:error, reason}
    end
  end

  defp go_back(state, udc, present, wanted) do
    now =
      state |> present(wanted) |> managed(state) |> Enum.filter(&(&1 in present or &1 in wanted))

    case switch(state, udc, now, present) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("kuroneko_gadget: USB functions not restored: #{inspect(reason)}")
    end
  end

  defp switch(state, udc, from, to) do
    {updates, removed, added} = plan(from -- to, to -- from)

    with :ok <- unbind(state.gadget),
         :ok <- each(removed, &remove(state, &1)),
         :ok <- each(updates, &update(state, &1)),
         :ok <- each(added, &add(state, &1)),
         :ok <-
           Configfs.write_existing(config_dir(state.gadget), [
             {"bmAttributes", @bus_powered_with_remote_wakeup}
           ]),
         :ok <- each(to, &ready(state, &1)) do
      bind(state, udc)
    end
  end

  defp plan(removed, added) do
    updates =
      for old <- removed,
          function_exported?(old.module, :update, 3),
          new <- Enum.filter(added, &(dir_name(&1) == dir_name(old))),
          do: {old, new}

    {olds, news} = Enum.unzip(updates)
    {updates, removed -- olds, added -- news}
  end

  defp add(state, instance) do
    dir = dir(state.gadget, instance)

    with :ok <- Configfs.mkdir(dir),
         :ok <- set_up(dir, instance),
         :ok <- default_addresses(state, dir, instance) do
      Configfs.link(dir, link_path(state.gadget, instance))
    end
  end

  defp set_up(dir, instance) do
    case run_callback(instance.module, :setup, [dir, instance.settings]) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = teardown(dir, instance)
        _ = Configfs.rmdir(dir)
        {:error, reason}
    end
  end

  defp default_addresses(state, dir, %{module: NCM} = instance) do
    if dir_name(instance) == state.network.function and state.network.default_addresses,
      do: NCM.write_addresses(dir, state.network.default_addresses),
      else: :ok
  end

  defp default_addresses(_state, _dir, _instance), do: :ok

  defp remove(state, instance) do
    dir = dir(state.gadget, instance)

    with :ok <- Configfs.unlink(link_path(state.gadget, instance)),
         :ok <- teardown(dir, instance),
         do: Configfs.rmdir(dir)
  end

  defp update(state, {old, new}) do
    dir = dir(state.gadget, old)

    with :ok <- Configfs.unlink(link_path(state.gadget, old)),
         :ok <- run_callback(old.module, :update, [dir, old.settings, new.settings]),
         do: Configfs.link(dir, link_path(state.gadget, new))
  end

  defp ready(state, instance) do
    if function_exported?(instance.module, :ready, 2),
      do: run_callback(instance.module, :ready, [dir(state.gadget, instance), instance.settings]),
      else: :ok
  end

  defp teardown(dir, instance) do
    if function_exported?(instance.module, :teardown, 2),
      do: run_callback(instance.module, :teardown, [dir, instance.settings]),
      else: :ok
  end

  # These change the system: an exception fails the change, which goes back,
  # instead of the process.
  defp run_callback(module, callback, args) do
    case apply(module, callback, args) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {module, exception}}
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A module's function is as this process set it up, else as asked for.
  defp present(state, wanted \\ []) do
    known = Map.merge(by_dir(wanted), state.module_functions)

    state.gadget
    |> linked_functions()
    |> Enum.flat_map(&recognize(&1, known))
    |> sort()
  end

  defp recognize(dir, known) do
    case Map.fetch(known, Path.basename(dir)) do
      {:ok, instance} -> read_known(dir, instance)
      :error -> Kinds.recognize(dir)
    end
  end

  defp read_known(dir, instance) do
    if function_exported?(instance.module, :read, 1) do
      case instance.module.read(dir) do
        {:ok, settings} -> [%{instance | settings: settings}]
        :error -> Kinds.recognize(dir)
      end
    else
      [instance]
    end
  end

  defp linked_functions(gadget) do
    config = config_dir(gadget)

    case File.ls(config) do
      {:ok, names} ->
        for name <- names,
            {:ok, target} <- [File.read_link(Path.join(config, name))],
            do: Path.expand(target, config)

      {:error, _reason} ->
        []
    end
  end

  defp managed(instances, %{network_managed: true}), do: instances
  defp managed(instances, _state), do: Enum.reject(instances, &(&1.module == NCM))

  defp network?(specs), do: Enum.any?(specs, &(&1 == :network or match?({:network, _opts}, &1)))

  defp kinds(instance) do
    case Kinds.describe(instance) do
      %{kind: :audio} = audio -> Enum.filter([:microphone, :speaker], &audio[&1])
      %{kind: kind} -> [kind]
    end
  end

  defp details(state, %{module: NCM} = instance) do
    dir = dir(state.gadget, instance)

    addresses =
      case NCM.read_addresses(dir) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> %{device_address: nil, host_address: nil}
      end

    instance
    |> Kinds.describe()
    |> Map.put(:interface, NCM.read_interface(dir))
    |> Map.merge(addresses)
  end

  defp details(_state, instance), do: Kinds.describe(instance)

  defp describe(instances), do: inspect(Enum.map(instances, &Kinds.describe/1))

  defp normalize(specs, defaults) when is_list(specs) do
    with {:ok, specs} <- Kinds.expand(specs, defaults),
         {:ok, instances} <- map_ok(specs, &instance/1),
         :ok <- unique(instances) do
      {:ok, sort(instances)}
    end
  end

  defp instance(module) when is_atom(module) do
    if function_module?(module),
      do: module_instance(module, []),
      else: {:error, {:unknown_function, module}}
  end

  defp instance({module, opts} = spec) when is_atom(module) and is_list(opts) do
    cond do
      not function_module?(module) -> {:error, {:unknown_function, spec}}
      not Keyword.keyword?(opts) -> {:error, {:invalid_options, spec}}
      true -> module_instance(module, opts)
    end
  end

  defp instance(other), do: {:error, {:unknown_function, other}}

  defp function_module?(module) do
    Code.ensure_loaded?(module) and
      __MODULE__.Function in List.flatten(
        Keyword.get_values(module.module_info(:attributes), :behaviour)
      )
  end

  defp module_instance(module, opts) do
    {name, opts} = Keyword.pop_lazy(opts, :name, &module.default_name/0)

    if Kinds.valid_name?(name) do
      with {:ok, settings} <- module.settings(opts),
           do: {:ok, %{module: module, name: name, settings: settings}}
    else
      {:error, {:invalid_name, module, name}}
    end
  end

  defp unique(instances) do
    case instances -- Enum.uniq_by(instances, &dir_name/1) do
      [] -> :ok
      [duplicate | _rest] -> {:error, {:duplicate_function, short(duplicate)}}
    end
  end

  defp short(instance) do
    %{kind: kind, name: name} = Kinds.describe(instance)
    default = if is_kind(kind), do: Kinds.default_name(kind), else: kind.default_name()
    if name == default, do: kind, else: {kind, name}
  end

  defp sort(instances), do: Enum.sort_by(instances, &{Kinds.rank(&1), dir_name(&1)})

  defp count_endpoints(instances) do
    Enum.reduce(instances, %{in: 0, out: 0}, fn instance, acc ->
      %{in: ins, out: outs} = instance.module.endpoints(instance.settings)
      %{in: acc.in + ins, out: acc.out + outs}
    end)
  end

  defp check_endpoints(_instances, nil), do: :ok

  defp check_endpoints(instances, have) do
    need = count_endpoints(instances)

    if need.in <= have.in and need.out <= have.out,
      do: :ok,
      else: {:error, {:not_enough_endpoints, %{need: need, have: have}}}
  end

  defp by_dir(instances), do: Map.new(instances, &{dir_name(&1), &1})

  defp dir_name(%{module: module, name: name}), do: "#{module.type()}.#{name}"
  defp dir(gadget, instance), do: Path.join([gadget, "functions", dir_name(instance)])
  defp config_dir(gadget), do: Path.join(gadget, @config)
  defp link_path(gadget, instance), do: Path.join(config_dir(gadget), dir_name(instance))
  defp soft_connect(state, udc), do: Path.join([state.udc_class, udc, "soft_connect"])

  defp check_gadget(gadget) do
    if File.dir?(gadget), do: :ok, else: {:error, {:no_gadget, gadget}}
  end

  defp bound_udc(gadget) do
    case Configfs.read_text(Path.join(gadget, "UDC")) do
      {:ok, ""} -> :unbound
      {:ok, udc} -> {:ok, udc}
      {:error, _reason} -> :unbound
    end
  end

  # A newline, since writing nothing does not reach the kernel.
  defp unbind(gadget) do
    case bound_udc(gadget) do
      {:ok, _udc} -> Configfs.write(Path.join(gadget, "UDC"), "\n")
      :unbound -> :ok
    end
  end

  defp bind(state, {:ok, udc}), do: Configfs.write(Path.join(state.gadget, "UDC"), udc)

  defp bind(state, :unbound) do
    case File.ls(state.udc_class) do
      {:ok, [udc | _others]} -> bind(state, {:ok, udc})
      _none -> {:error, :no_udc}
    end
  end

  defp read_network(state) do
    dir = Path.join([state.gadget, "functions", state.network.function])

    with :ok <- check_gadget(state.gadget),
         {:ok, addresses} <- NCM.read_addresses(dir) do
      {:ok,
       Map.merge(addresses, %{
         interface: NCM.read_interface(dir),
         default_addresses: state.network.default_addresses
       })}
    end
  end

  defp wanted_addresses(settings, network) do
    with :ok <- check_network_settings(settings),
         {:ok, device} <- wanted_address(:device_address, settings, network),
         {:ok, host} <- wanted_address(:host_address, settings, network) do
      if device == host,
        do: {:error, :same_addresses},
        else: {:ok, %{device_address: device, host_address: host}}
    end
  end

  defp check_network_settings(settings) do
    if Keyword.keyword?(settings),
      do: check_network_keys(settings),
      else: {:error, {:invalid_settings, settings}}
  end

  defp check_network_keys(settings) do
    case Keyword.validate(settings, [:device_address, :host_address, persist: true]) do
      {:ok, settings} ->
        if is_boolean(settings[:persist]),
          do: :ok,
          else: {:error, {:invalid_persist, settings[:persist]}}

      {:error, unknown} ->
        {:error, {:unknown_options, unknown}}
    end
  end

  defp wanted_address(key, settings, network) do
    case Keyword.fetch(settings, key) do
      :error -> {:ok, Map.fetch!(network, key)}
      {:ok, :default} -> default_address(key, network.default_addresses)
      {:ok, text} -> unicast_address(key, text)
    end
  end

  defp default_address(_key, nil), do: {:error, :no_default_addresses}
  defp default_address(key, defaults), do: {:ok, Map.fetch!(defaults, key)}

  defp unicast_address(key, text) do
    case MAC.parse(text) do
      {:ok, <<0::48>>} ->
        {:error, {:invalid_address, key, text}}

      {:ok, bytes} ->
        if MAC.multicast?(bytes),
          do: {:error, {:multicast_address, key, text}},
          else: {:ok, MAC.format(bytes)}

      :error ->
        {:error, {:invalid_address, key, text}}
    end
  end

  defp readdress(_state, same, same), do: :ok

  defp readdress(state, current, wanted) do
    Logger.info(
      "kuroneko_gadget: USB network addresses #{inspect(wanted)}, reconnecting the gadget"
    )

    udc = bound_udc(state.gadget)
    links = links_in_order(state)
    dir = Path.join([state.gadget, "functions", state.network.function])

    result =
      with :ok <- unbind(state.gadget),
           :ok <- each(links, &Configfs.unlink(Path.join(config_dir(state.gadget), &1))),
           do: NCM.readdress(dir, current, wanted)

    # The functions go back in their order and the gadget connects again,
    # also when the addresses did not take.
    with :ok <- each(links, &relink(state.gadget, &1)),
         :ok <- bind(state, udc),
         do: result
  end

  defp links_in_order(state) do
    links = Enum.map(linked_functions(state.gadget), &Path.basename/1)
    known = Enum.map(present(state), &dir_name/1)
    ordered = Enum.filter(known, &(&1 in links)) ++ (links -- known)
    {network, others} = Enum.split_with(ordered, &(&1 == state.network.function))
    network ++ others
  end

  defp relink(gadget, name) do
    case Configfs.link(
           Path.join([gadget, "functions", name]),
           Path.join(config_dir(gadget), name)
         ) do
      {:error, {:configfs, _path, :eexist}} -> :ok
      result -> result
    end
  end

  defp persist(%{network: %{persist: nil}}, _settings, _wanted), do: :ok

  defp persist(state, settings, wanted) do
    kept =
      for key <- [:device_address, :host_address], Keyword.has_key?(settings, key), into: %{} do
        {key, if(settings[key] == :default, do: :default, else: wanted[key])}
      end

    if kept == %{} do
      :ok
    else
      case state.network.persist.(kept) do
        :ok -> :ok
        {:error, reason} -> {:error, {:not_kept, reason}}
      end
    end
  end

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end

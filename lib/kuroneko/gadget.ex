defmodule Kuroneko.Gadget do
  @configfs "/sys/kernel/config/usb_gadget"

  @moduledoc """
  The USB functions the target computer sees, on a USB gadget in configfs.

  The system sets up the gadget at boot, often with a network function, and
  binds it to the device controller. This process adds the KVM functions to
  it:

    * `:keyboard` - a boot keyboard, for `Kuroneko.Gadget.HID`
    * `:mouse` - an absolute pointer, for `Kuroneko.Gadget.HID`; `{:mouse,
      mode: mode}` makes it an `:absolute` mouse (the default), a `:stylus`
      (a pen, for Android and iPadOS) or a `:touch` screen
    * `:relative_mouse` - a boot mouse that moves by steps, for
      `Kuroneko.Gadget.HID`, which BIOS setups and games take
    * `:storage` - a USB mass storage device, removable drives or optical
      drives, for `Kuroneko.Gadget.Storage`. Its logical units (LUNs) are the
      drives the target sees: `{:storage, luns: 3}` has three, up to 16, on
      the endpoints of one
    * `:network` - a USB network adapter (NCM), see "The network" below
    * `:microphone` - a microphone the target computer records from
    * `:speaker` - a speaker the target computer plays to

  There may be several functions of a kind, each with a `:name`:
  `[:storage, {:storage, name: "boot"}]` are two storage functions, which the
  target sees as two devices, each with its own LUN 0. Without a name a function is its kind's first:
  `"keyboard"`, `"mouse"`, `"relative_mouse"`, `"disk"`, `"usb0"`, `"audio"`.
  Names take letters, digits, `_` and `-`. `instances/1` tells what the
  gadget has.

  Each function takes endpoints of the device controller, which has few:
  HID functions one IN, a storage function one IN and one OUT, a network
  function two IN and one OUT, the microphone one IN, the speaker one OUT
  (`endpoints/1`). With the `:endpoints` option, the functions asked for
  must fit, or `configure/2` says how many they need and how many there are.

  The microphone and the speaker are the two directions of one USB Audio
  Class 2 function, which Linux shows as the ALSA card `UAC2Gadget`. Each
  takes its format as options, `{:microphone, options}`:

    * `:channels` - 1 (mono) to 8, 2 (stereo) by default
    * `:rates` - the sample rates the target computer can choose from, up to
      10, `[48_000]` by default. The target starts with the first and
      chooses (a Mac in Audio MIDI Setup, Windows in the device's
      properties).
    * `:sample_bits` - 16, 24 or 32, 16 by default

  The target's volume and mute controls act on the samples. The keyboard
  and mice may wake a target that sleeps, where it allows them. A format
  whose packets the device controller cannot carry (`:max_packet`) is
  refused. `audio/1` tells the formats the gadget has.

  Changing the functions disconnects the gadget and connects it again: the
  target computer sees the device unplugged and plugged in, and the USB
  network goes down for a moment. With the functions already there nothing
  happens, so starting the process again is cheap.

  When the functions cannot be set up at start, the process logs the error
  and runs on, so that the rest of the application does not go down with
  it; `functions/1` tells what the gadget has. A change the device
  controller refuses (each function takes endpoints, and controllers have
  few) leaves the functions as they were.

      children = [
        {Kuroneko.Gadget,
         functions: [:keyboard, :mouse, {:microphone, channels: 1, rates: [44_100, 48_000]}]}
      ]

  ## The network

  A network function the system set up has two MAC addresses: the device's,
  of its interface, and the target computer's, of the network adapter the
  computer sees. `network/1` tells them; `set_network_addresses/2` changes
  them at once, and the `:persist` function of the `:network` option keeps
  them for the next boots.

  The functions take network functions in hand only when they include a
  `:network`, or always with `manage_networks: true`: then `[:network,
  {:network, name: "usb1"}]` keeps the system's network and adds a second,
  whose interface the kernel names, and a list without the system's network
  removes it, one without any network all of them. Another network's addresses are
  made from the gadget's serial number and the function's name, the same at
  each boot; the system's network, made again, takes the default addresses.

  ## Options

    * `:functions` - the functions to have, none by default
    * `:name` - the name to register, `Kuroneko.Gadget` by default
    * `:gadget` - the gadget's configfs directory, `default_gadget/0` by
      default
    * `:endpoints` - the device controller's endpoints besides endpoint 0,
      `%{in: 7, out: 7}`; not checked without it
    * `:max_packet` - the largest packets the device controller takes for
      the `:microphone` and the `:speaker`, in bytes: 1024 each by default,
      the most high speed carries
    * `:names` - what the target computer calls the functions, the kernel's
      names for those left out: `:audio` (the sound card), `:microphone`,
      `:speaker`, and `:storage` (the drive) as `{vendor, product,
      revision}` of up to 8, 16 and 4 ASCII characters
    * `:manage_networks` - whether the network functions are always this
      module's, so that functions without one remove them all; by default
      only when the functions include one
    * `:network` - the network function:
      * `:function` - its configfs directory, `"ncm.usb0"` by default
      * `:default_addresses` - the addresses `:default` stands for in
        `set_network_addresses/2`
      * `:persist` - a function that keeps addresses for the next boots. It
        takes those `set_network_addresses/2` was given, a map with
        `:device_address`, `:host_address` or both, each an address or
        `:default`, and returns `:ok` or `{:error, reason}`

  Board libraries give these for their boards, such as
  `NanoKVMGo.USB.gadget_options/1` for the Sipeed NanoKVM-Go.
  """
  use GenServer
  require Logger
  import Bitwise

  alias Kuroneko.Gadget.HID.Descriptor

  @config "configs/c.1"
  @udc_class "/sys/class/udc"
  # Each kind's configfs type, and the name of its instance by default.
  @types %{
    keyboard: "hid",
    mouse: "hid",
    relative_mouse: "hid",
    storage: "mass_storage",
    network: "ncm",
    microphone: "uac2",
    speaker: "uac2",
    audio: "uac2"
  }
  @default_names %{
    keyboard: "keyboard",
    mouse: "mouse",
    relative_mouse: "relative_mouse",
    storage: "disk",
    network: "usb0",
    microphone: "audio",
    speaker: "audio",
    audio: "audio"
  }
  # The order they are added in: the network first, the keyboard before the
  # mouse. The microphone and speaker of a name are one audio function.
  @order [:network, :keyboard, :mouse, :relative_mouse, :storage, :audio]
  @audio [:microphone, :speaker]
  @hid [:keyboard, :mouse, :relative_mouse]
  @max_luns 16
  # The LUN settings a storage function keeps when it changes, in the order
  # they are written back: the medium last.
  @lun_settings [:removable, :cdrom, :profile, :ro, :nofua, :inquiry_string, :file]
  # The configfs attributes of the audio directions start with these.
  @prefix %{microphone: "p_", speaker: "c_"}
  # Channel positions: front left and right, center, LFE, back, side.
  @channel_masks %{
    1 => 0x1,
    2 => 0x3,
    3 => 0x7,
    4 => 0x33,
    5 => 0x37,
    6 => 0x3F,
    7 => 0x13F,
    8 => 0x63F
  }
  @max_rates 10
  @max_packet %{microphone: 1024, speaker: 1024}
  # The device controller's states and speeds in sysfs (usb_state_string,
  # usb_speed_string).
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
    "super-speed-plus" => :super_speed_plus,
    "UNKNOWN" => :unknown
  }
  # The network function's settings that a new one takes over.
  @network_kept [:qmult, :max_segment_size]

  @type function_name() ::
          :keyboard | :mouse | :relative_mouse | :storage | :network | :microphone | :speaker

  @type audio_option() ::
          {:channels, 1..8} | {:rates, [pos_integer()]} | {:sample_bits, 16 | 24 | 32}

  @typedoc """
  A function to have: its kind alone, or with options, `:name` among them.
  See the module documentation.
  """
  @type function_spec() ::
          function_name()
          | {:microphone | :speaker, [audio_option() | {:name, String.t()}]}
          | {:mouse, [mode: Kuroneko.Gadget.HID.pointer_mode(), name: String.t()]}
          | {:storage, [luns: 1..16, name: String.t()]}
          | {:keyboard | :relative_mouse | :network, [name: String.t()]}

  @typedoc "A function on the gadget, see `instances/1`."
  @type instance() :: %{
          required(:kind) => atom(),
          required(:name) => String.t(),
          optional(atom()) => term()
        }

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

  @type audio_format() :: %{
          channels: 1..8,
          rates: [pos_integer(), ...],
          sample_bits: 16 | 24 | 32
        }

  @typedoc "A MAC address, such as `\"02:12:34:56:78:9a\"`."
  @type mac_address() :: String.t()

  @type network_addresses() :: %{device_address: mac_address(), host_address: mac_address()}

  @typedoc "The USB network, see `network/1`."
  @type network() :: %{
          interface: String.t() | nil,
          device_address: mac_address(),
          host_address: mac_address(),
          default_addresses: network_addresses() | nil
        }

  @typedoc "What `set_network_addresses/2` takes."
  @type network_setting() ::
          {:device_address, mac_address() | :default}
          | {:host_address, mac_address() | :default}
          | {:persist, boolean()}

  @typedoc "Addresses to keep for the next boots, see the `:network` option."
  @type kept_addresses() :: %{
          optional(:device_address | :host_address) => mac_address() | :default
        }

  @type name_option() ::
          {:audio | :microphone | :speaker, String.t()}
          | {:storage, {String.t(), String.t(), String.t()}}

  @type network_option() ::
          {:function, String.t()}
          | {:default_addresses, network_addresses() | nil}
          | {:persist, (kept_addresses() -> :ok | {:error, term()}) | nil}

  @type option() ::
          {:functions, [function_spec()]}
          | {:name, GenServer.name()}
          | {:gadget, Path.t()}
          | {:max_packet, %{optional(:microphone | :speaker) => pos_integer()}}
          | {:names, [name_option()]}
          | {:network, [network_option()]}
          | {:endpoints, %{in: non_neg_integer(), out: non_neg_integer()}}

  @doc """
  Starts the process and sets up the functions. See the module documentation
  for the options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sets up these functions and removes the other KVM functions. Network
  functions are among them when the list has a `:network`; without one, the
  network the system set up stays as it is.

      Kuroneko.Gadget.configure([:keyboard, :mouse, {:storage, luns: 3}])
      Kuroneko.Gadget.configure([:keyboard, :storage, {:storage, name: "boot"}])
      Kuroneko.Gadget.configure([:network, {:network, name: "usb1"}, :keyboard])
  """
  @spec configure(GenServer.server(), [function_spec()]) :: :ok | {:error, term()}
  def configure(server \\ __MODULE__, functions) when is_list(functions) do
    GenServer.call(server, {:configure, functions})
  end

  @doc """
  Checks functions without setting them up: whether `configure/2` would
  take them from a process started with these options (`:max_packet` and
  `:endpoints` count; `configure/2` also counts the network functions it
  leaves alone).

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
    with {:ok, instances} <- normalize(functions, max_packet(opts)),
         do: check_endpoints(instances, Keyword.get(opts, :endpoints))
  end

  @doc """
  The kinds of KVM functions the gadget has, each once.
  """
  @spec functions(GenServer.server()) :: [function_name()]
  def functions(server \\ __MODULE__), do: GenServer.call(server, :functions)

  @doc """
  The functions on the gadget that this module knows, each with its kind and
  name, as `configure/2` takes them back. A network also has its interface
  on the device (`nil` before the gadget is first bound) and its addresses:

      [%{kind: :network, name: "usb0", interface: "usb0",
         device_address: "9e:9f:51:11:f7:b2", host_address: "7a:78:1f:1f:1d:dd"},
       %{kind: :keyboard, name: "keyboard"},
       %{kind: :storage, name: "disk", luns: 2},
       %{kind: :audio, name: "audio", microphone: %{channels: 2, ...}, speaker: nil}]
  """
  @spec instances(GenServer.server()) :: [instance()]
  def instances(server \\ __MODULE__), do: GenServer.call(server, :instances)

  @doc """
  The endpoints the functions take: each HID function one IN, a storage
  function one of each whatever its LUNs, a network function two IN and one
  OUT, a microphone one IN, a speaker one OUT. Endpoint 0 is not counted.

      iex> Kuroneko.Gadget.endpoints([:keyboard, :mouse, {:storage, luns: 4}, :network])
      {:ok, %{in: 5, out: 2}}
  """
  @spec endpoints([function_spec()]) ::
          {:ok, %{in: non_neg_integer(), out: non_neg_integer()}} | {:error, term()}
  def endpoints(functions) do
    with {:ok, instances} <- normalize(functions, max_packet([])),
         do: {:ok, count_endpoints(instances)}
  end

  @doc """
  The endpoints the gadget's functions take now, the network functions this
  module leaves alone among them, and those the controller has (the
  `:endpoints` option, `nil` without it):

      Kuroneko.Gadget.endpoints_in_use()
      #=> %{in: 7, out: 3, have: %{in: 7, out: 7}}
  """
  @spec endpoints_in_use(GenServer.server()) :: %{
          in: non_neg_integer(),
          out: non_neg_integer(),
          have: %{in: non_neg_integer(), out: non_neg_integer()} | nil
        }
  def endpoints_in_use(server \\ __MODULE__), do: GenServer.call(server, :endpoints_in_use)

  @doc """
  The formats of the audio directions of the sound card named `"audio"`,
  the default one, such as `%{microphone: %{channels: 2, rates: [48_000],
  sample_bits: 16}}`. `instances/1` tells those of any sound card.
  """
  @spec audio(GenServer.server()) :: %{optional(:microphone | :speaker) => audio_format()}
  def audio(server \\ __MODULE__), do: GenServer.call(server, :audio)

  @doc """
  Takes the gadget off the USB bus and puts it back, so that the target
  computer finds it anew, as if it had been unplugged: all of its devices
  reconnect. A computer reads what kind of drive a mass storage logical
  unit is only then. Takes `:gadget` and `:udc_class` as `connection/1`
  does, and `:replug_ms`, how long the gadget is off the bus, 1500 by
  default. A gadget on no device controller stays as it is.
  """
  @spec replug(keyword()) :: :ok | {:error, term()}
  def replug(opts \\ []) do
    udc_class = Keyword.get(opts, :udc_class, @udc_class)

    case bound_udc(Keyword.get_lazy(opts, :gadget, &default_gadget/0)) do
      "" ->
        :ok

      udc ->
        control = Path.join([udc_class, udc, "soft_connect"])

        with :ok <- File.write(control, "disconnect") do
          Process.sleep(Keyword.get(opts, :replug_ms, 1500))
          File.write(control, "connect")
        end
    end
  end

  @doc """
  The USB connection to the target computer: the state the target has put
  the device in, the speed, and the device controller.

    * `:configured` - the target uses the functions
    * `:suspended` - the target sleeps, or has suspended the port
    * `:not_attached` - no computer at the other end of the cable
    * `:attached`, `:powered`, `:default`, `:addressed` - on the way to
      `:configured`

  ```
  Kuroneko.Gadget.connection()
  #=> {:ok, %{state: :configured, speed: :high_speed, controller: "8000000.usb"}}
  ```

  The speed is `:low_speed`, `:full_speed`, `:high_speed`, `:super_speed`
  or `:unknown`. Without a controller bound to the gadget the result is
  `{:error, :no_udc}`. Takes the `:gadget` option.
  """
  @spec connection(keyword()) ::
          {:ok, %{state: connection_state(), speed: speed(), controller: String.t()}}
          | {:error, term()}
  def connection(opts \\ []) do
    udc_class = Keyword.get(opts, :udc_class, @udc_class)

    with udc when udc != "" <- bound_udc(Keyword.get_lazy(opts, :gadget, &default_gadget/0)),
         dir = Path.join(udc_class, udc),
         {:ok, state} <- File.read(Path.join(dir, "state")) do
      speed =
        case File.read(Path.join(dir, "current_speed")) do
          {:ok, speed} -> Map.get(@speeds, String.trim(speed), :unknown)
          {:error, _reason} -> :unknown
        end

      {:ok,
       %{state: Map.get(@states, String.trim(state), :unknown), speed: speed, controller: udc}}
    else
      "" -> {:error, :no_udc}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The USB network the system set up (the `:network` option's function): the
  device's interface and its address, the address of the target computer's
  end, and the addresses `:default` stands for.

  ```
  Kuroneko.Gadget.network()
  #=> {:ok,
  #=>  %{
  #=>    interface: "usb0",
  #=>    device_address: "9e:9f:51:11:f7:b2",
  #=>    host_address: "02:12:34:56:78:9a",
  #=>    default_addresses: %{device_address: "9e:9f:51:11:f7:b2", host_address: "7a:78:1f:1f:1d:dd"}
  #=>  }}
  ```

  The interface is `nil` before the gadget is first bound, and the default
  addresses `nil` without the `:network` option's `:default_addresses`.
  """
  @spec network(GenServer.server()) :: {:ok, network()} | {:error, term()}
  def network(server \\ __MODULE__), do: GenServer.call(server, :network)

  @doc """
  Gives the USB network other addresses, MAC addresses or `:default`:

    * `:device_address` - the device's
    * `:host_address` - the target computer's

  One left out stays as it is. The gadget connects again, as when the
  functions change, and the device's interface goes away and comes back
  with its address. The `:network` option's `:persist` function keeps the
  addresses for the next boots, unless `persist: false`.

  ```
  Kuroneko.Gadget.set_network_addresses(host_address: "02:12:34:56:78:9a")
  Kuroneko.Gadget.set_network_addresses(device_address: :default, host_address: :default)
  ```

  Refused: an address that is not one (`{:invalid_address, key, value}`)
  or is a multicast address (`{:multicast_address, key, value}`), and the
  same address at both ends (`:same_addresses`). Addresses set but not
  kept give `{:error, {:not_kept, reason}}`.
  """
  @spec set_network_addresses(GenServer.server(), [network_setting()]) :: :ok | {:error, term()}
  def set_network_addresses(server \\ __MODULE__, settings) when is_list(settings) do
    GenServer.call(server, {:set_network_addresses, settings}, 15_000)
  end

  @doc """
  Checks addresses without setting them: whether `set_network_addresses/2`
  would take them.
  """
  @spec validate_network_addresses(GenServer.server(), [network_setting()]) ::
          :ok | {:error, term()}
  def validate_network_addresses(server \\ __MODULE__, settings) when is_list(settings) do
    GenServer.call(server, {:validate_network_addresses, settings})
  end

  @doc """
  The gadget the functions go on when none is given: the `:gadget` in the
  `:kuroneko_gadget` application environment, else the only gadget in
  configfs, else `#{@configfs}/kuroneko`.
  """
  @spec default_gadget() :: Path.t()
  def default_gadget do
    Application.get_env(:kuroneko_gadget, :gadget) || only_gadget(@configfs)
  end

  @doc false
  @spec only_gadget(Path.t()) :: Path.t()
  def only_gadget(configfs) do
    case File.ls(configfs) do
      {:ok, [name]} -> Path.join(configfs, name)
      _none_or_several -> Path.join(configfs, "kuroneko")
    end
  end

  @doc """
  The device of a HID function, such as `"/dev/hidg0"`: the kind's default
  one, or the one `:name` names.

  Takes the `:gadget` option.

      Kuroneko.Gadget.hid_device(:keyboard)
      Kuroneko.Gadget.hid_device(:keyboard, name: "keyboard2")
  """
  @spec hid_device(:keyboard | :mouse | :relative_mouse, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def hid_device(function, opts \\ []) when function in [:keyboard, :mouse, :relative_mouse] do
    dev = Path.join(function_dir(function, opts), "dev")

    with {:ok, text} <- File.read(dev),
         [major, minor] <- text |> String.trim() |> String.split(":"),
         {:ok, uevent} <- File.read("/sys/dev/char/#{major}:#{minor}/uevent"),
         [_line, name] <- Regex.run(~r/^DEVNAME=(.+)$/m, uevent) do
      {:ok, "/dev/" <> name}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_device}
    end
  end

  @doc false
  # A function's directory: `:name` picks the instance, the kind's default
  # one without it.
  @spec function_dir(function_name(), keyword()) :: Path.t()
  def function_dir(function, opts) do
    gadget = Keyword.get_lazy(opts, :gadget, &default_gadget/0)
    name = Keyword.get(opts, :name) || @default_names[function]
    Path.join([gadget, "functions", "#{@types[function]}.#{name}"])
  end

  @impl GenServer
  def init(opts) do
    functions = Keyword.get(opts, :functions, [])
    max_packet = max_packet(opts)
    names = Keyword.get(opts, :names, [])
    network = Keyword.get(opts, :network, [])

    with {:error, reason} <- normalize(functions, max_packet) do
      raise ArgumentError, "invalid USB functions: #{inspect(reason)}"
    end

    Enum.each(names, &check_name!/1)

    state = %{
      gadget: Keyword.get_lazy(opts, :gadget, &default_gadget/0),
      max_packet: max_packet,
      endpoints: Keyword.get(opts, :endpoints),
      manage_networks: Keyword.get(opts, :manage_networks, false),
      network_managed: Keyword.get(opts, :manage_networks, false) or network?(functions),
      names: Map.new(names),
      network: %{
        function: Keyword.get(network, :function, "ncm.usb0"),
        default_addresses: Keyword.get(network, :default_addresses),
        persist: Keyword.get(network, :persist)
      },
      # For tests: where the device controllers are listed, and how a
      # function goes (configfs takes its attributes with it, a plain
      # directory does not).
      udc_class: Keyword.get(opts, :udc_class, @udc_class),
      rmdir: Keyword.get(opts, :rmdir, &File.rmdir/1)
    }

    with {:error, reason} <- apply_functions(state, functions) do
      Logger.error(
        "kuroneko_gadget: USB functions #{inspect(functions)} not set up: #{inspect(reason)}"
      )
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:configure, functions}, _from, state) do
    case apply_functions(state, functions) do
      :ok -> {:reply, :ok, %{state | network_managed: managing_networks?(state, functions)}}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:functions, _from, state) do
    kinds =
      state
      |> managed(present(state.gadget))
      |> Enum.flat_map(fn
        %{kind: :audio} = audio -> Enum.filter(@audio, &audio[&1])
        %{kind: kind} -> [kind]
      end)
      |> Enum.uniq()

    {:reply, kinds, state}
  end

  def handle_call(:instances, _from, state),
    do: {:reply, Enum.map(present(state.gadget), &with_details(state, &1)), state}

  def handle_call(:endpoints_in_use, _from, state),
    do: {:reply, Map.put(count_endpoints(present(state.gadget)), :have, state.endpoints), state}

  def handle_call(:audio, _from, state) do
    audio =
      case Enum.find(present(state.gadget), &match?(%{kind: :audio, name: "audio"}, &1)) do
        nil ->
          %{}

        unit ->
          for direction <- @audio, unit[direction], into: %{}, do: {direction, unit[direction]}
      end

    {:reply, audio, state}
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

  defp max_packet(opts), do: Map.merge(@max_packet, Map.new(Keyword.get(opts, :max_packet, %{})))

  defp check_name!(name) do
    valid =
      case name do
        {key, text} when key in [:audio, :microphone, :speaker] ->
          is_binary(text)

        {:storage, {vendor, product, revision}} ->
          Enum.all?([vendor, product, revision], &is_binary/1)

        _other ->
          false
      end

    valid || raise ArgumentError, "invalid USB function name: #{inspect(name)}"
  end

  defp read_network(state) do
    dir = Path.join([state.gadget, "functions", state.network.function])

    with :ok <- check_gadget(state.gadget),
         {:ok, device} <- read_address(dir, "dev_addr"),
         {:ok, host} <- read_address(dir, "host_addr") do
      {:ok,
       %{
         interface: read_interface(dir),
         device_address: device,
         host_address: host,
         default_addresses: state.network.default_addresses
       }}
    end
  end

  # configfs shows an address with a NUL and a newline after it.
  defp read_address(dir, attribute) do
    with {:ok, text} <- File.read(Path.join(dir, attribute)),
         {:ok, bytes} <- parse_address(String.replace(text, ["\0", "\n"], "")) do
      {:ok, format_address(bytes)}
    else
      _ -> {:error, {:no_network_address, attribute}}
    end
  end

  # An interface not registered yet is "(unnamed net_device)".
  defp read_interface(dir) do
    case File.read(Path.join(dir, "ifname")) do
      {:ok, "(" <> _unnamed} -> nil
      {:ok, name} -> String.trim(name)
      {:error, _reason} -> nil
    end
  end

  # The addresses asked for, those left out as they are.
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
    cond do
      not Keyword.keyword?(settings) ->
        {:error, {:invalid_settings, settings}}

      (unknown = Keyword.keys(settings) -- [:device_address, :host_address, :persist]) != [] ->
        {:error, {:unknown_options, unknown}}

      Keyword.get(settings, :persist, true) not in [true, false] ->
        {:error, {:invalid_persist, settings[:persist]}}

      true ->
        :ok
    end
  end

  defp wanted_address(key, settings, network) do
    case Keyword.fetch(settings, key) do
      :error -> {:ok, network[key]}
      {:ok, :default} -> default_address(key, network.default_addresses)
      {:ok, text} -> unicast_address(key, text)
    end
  end

  defp default_address(_key, nil), do: {:error, :no_default_addresses}
  defp default_address(key, defaults), do: {:ok, defaults[key]}

  defp unicast_address(key, text) do
    case parse_address(text) do
      {:ok, <<first, _rest::binary>>} when (first &&& 1) == 1 ->
        {:error, {:multicast_address, key, text}}

      {:ok, <<0::48>>} ->
        {:error, {:invalid_address, key, text}}

      {:ok, bytes} ->
        {:ok, format_address(bytes)}

      :error ->
        {:error, {:invalid_address, key, text}}
    end
  end

  # Six bytes with colons or hyphens between them, in either case.
  defp parse_address(text) when is_binary(text) do
    with [_, _, _, _, _, _] = parts <- String.split(text, [":", "-"]),
         true <- Enum.all?(parts, &(byte_size(&1) == 2)),
         {:ok, bytes} <- Base.decode16(Enum.join(parts), case: :mixed) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp parse_address(_other), do: :error

  defp format_address(bytes) do
    Enum.map_join(:binary.bin_to_list(bytes), ":", &Base.encode16(<<&1>>, case: :lower))
  end

  defp readdress(_state, same, same), do: :ok

  defp readdress(state, current, wanted) do
    Logger.info(
      "kuroneko_gadget: USB network addresses #{inspect(wanted)}, reconnecting the gadget"
    )

    gadget = state.gadget
    udc = bound_udc(gadget)
    links = links(state)

    result =
      with :ok <- unbind(gadget, udc),
           :ok <- each(links, &unlink(gadget, &1)) do
        write_addresses(state, current, wanted)
      end

    # The functions go back in their order and the gadget connects again,
    # also when the addresses did not take.
    with :ok <- each(links, &relink(gadget, &1)),
         :ok <- bind(state, udc),
         do: result
  end

  # The configuration's functions, in the order to link them again: the
  # network first, then the KVM functions and any others.
  defp links(state) do
    config = Path.join(state.gadget, @config)

    rank = fn {name, function} ->
      kind =
        case instance_of(function) do
          [%{kind: kind}] -> kind
          [] -> nil
        end

      {if(name == state.network.function, do: 0, else: 1),
       Enum.find_index(@order, &(&1 == kind)) || length(@order), name}
    end

    case File.ls(config) do
      {:ok, names} -> names |> Enum.flat_map(&link_target(config, &1)) |> Enum.sort_by(rank)
      {:error, _reason} -> []
    end
  end

  # The kernel takes a relative target from the caller's directory.
  defp link_target(config, name) do
    case File.read_link(Path.join(config, name)) do
      {:ok, function} -> [{name, Path.expand(function, config)}]
      {:error, _not_a_link} -> []
    end
  end

  defp unlink(gadget, {name, _function}), do: File.rm(Path.join([gadget, @config, name]))

  defp relink(gadget, {name, function}) do
    case File.ln_s(function, Path.join([gadget, @config, name])) do
      {:error, :eexist} -> :ok
      result -> result
    end
  end

  # The device's address is that of its interface, which the function makes
  # when it is first bound: another address takes a new function. The
  # computer's is read when the function is linked.
  defp write_addresses(state, current, wanted) do
    dir = Path.join([state.gadget, "functions", state.network.function])

    if wanted.device_address == current.device_address do
      write_all(dir, host_addr: wanted.host_address)
    else
      kept =
        for name <- @network_kept,
            {:ok, value} <- [File.read(Path.join(dir, Atom.to_string(name)))],
            do: {name, String.trim(value)}

      with :ok <- state.rmdir.(dir),
           :ok <- File.mkdir(dir),
           :ok <- write_all(dir, kept) do
        write_all(dir, dev_addr: wanted.device_address, host_addr: wanted.host_address)
      end
    end
  end

  # The addresses asked for, or :default, to the :persist function.
  defp persist(%{network: %{persist: nil}}, _settings, _wanted), do: :ok

  defp persist(state, settings, wanted) do
    kept =
      for key <- [:device_address, :host_address], Keyword.has_key?(settings, key), into: %{} do
        {key, if(settings[key] == :default, do: :default, else: wanted[key])}
      end

    if kept == %{}, do: :ok, else: keep(state.network.persist, kept)
  end

  defp keep(persist, kept) do
    case persist.(kept) do
      :ok -> :ok
      {:error, reason} -> {:error, {:not_kept, reason}}
    end
  end

  # The network functions left alone count against the endpoints too.
  defp apply_functions(state, functions) do
    with {:ok, wanted} <- normalize(functions, state.max_packet),
         :ok <- check_gadget(state.gadget),
         {present, others} =
           Enum.split_with(
             present(state.gadget),
             &(managing_networks?(state, functions) or &1.kind != :network)
           ),
         :ok <- check_endpoints(wanted ++ others, state.endpoints) do
      if wanted == present,
        do: :ok,
        else: change(state, present, wanted)
    end
  end

  # A network with its interface and addresses.
  defp with_details(state, %{kind: :network} = network) do
    dir = dir(state.gadget, network)

    Map.merge(network, %{
      interface: read_interface(dir),
      device_address: address_or_nil(dir, "dev_addr"),
      host_address: address_or_nil(dir, "host_addr")
    })
  end

  defp with_details(_state, instance), do: instance

  defp address_or_nil(dir, attribute) do
    case read_address(dir, attribute) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  # The KVM functions: the network ones only when they are managed.
  defp managed(state, instances),
    do: Enum.filter(instances, &(state.network_managed or &1.kind != :network))

  defp managing_networks?(state, functions), do: state.manage_networks or network?(functions)

  defp network?(functions),
    do: Enum.any?(functions, &(&1 == :network or match?({:network, _}, &1)))

  defp change(state, present, wanted) do
    Logger.info("kuroneko_gadget: USB functions #{inspect(wanted)}, reconnecting the gadget")
    udc = bound_udc(state.gadget)

    with {:error, reason} <- switch(state, udc, present, wanted) do
      Logger.error(
        "kuroneko_gadget: USB functions #{inspect(wanted)} refused: #{inspect(reason)}"
      )

      now =
        state |> managed(present(state.gadget)) |> Enum.filter(&(&1 in present or &1 in wanted))

      _ = switch(state, udc, now, present)
      {:error, reason}
    end
  end

  # A storage function that changes keeps the media of the LUNs it keeps.
  defp switch(state, udc, from, to) do
    kept =
      for %{kind: :storage, name: name} = old <- from -- to,
          Enum.any?(to -- from, &match?(%{kind: :storage, name: ^name}, &1)),
          into: %{},
          do: {name, lun_settings(dir(state.gadget, old))}

    with :ok <- unbind(state.gadget, bound_udc(state.gadget)),
         :ok <- each(from -- to, &remove(state, &1)),
         :ok <- each(to -- from, &add(state, &1, kept)),
         # Bus powered, and the keyboard and mice may wake the target.
         :ok <- write_existing(Path.join(state.gadget, @config), bmAttributes: "0xa0") do
      bind(state, udc)
    end
  end

  # The functions in the configuration that this module knows, in order.
  defp present(gadget) do
    config = Path.join(gadget, @config)

    case File.ls(config) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&link_target(config, &1))
        |> Enum.flat_map(fn {_name, function} -> instance_of(function) end)
        |> sort()

      {:error, _reason} ->
        []
    end
  end

  defp sort(instances),
    do:
      Enum.sort_by(instances, &{Enum.find_index(@order, fn kind -> kind == &1.kind end), &1.name})

  # What a function directory is, from its type and settings. HID functions
  # are known by their report descriptors, or by the names of this module's.
  defp instance_of(dir) do
    case String.split(Path.basename(dir), ".", parts: 2) do
      ["hid", name] -> hid_instance(dir, name)
      ["mass_storage", name] -> [%{kind: :storage, name: name, luns: max(count_luns(dir), 1)}]
      ["ncm", name] -> [%{kind: :network, name: name}]
      ["uac2", name] -> audio_instance(dir, name)
      _other -> []
    end
  end

  defp hid_instance(dir, name) do
    report_desc =
      case File.read(Path.join(dir, "report_desc")) do
        {:ok, data} -> data
        {:error, _reason} -> nil
      end

    case hid_kind(report_desc) || default_hid(name) do
      nil -> []
      {kind, extra} -> [Map.merge(%{kind: kind, name: name}, extra)]
    end
  end

  # A HID function by its report descriptor.
  defp hid_kind(nil), do: nil

  defp hid_kind(report_desc) do
    cond do
      report_desc == Descriptor.keyboard().report_desc -> {:keyboard, %{}}
      report_desc == Descriptor.relative_mouse().report_desc -> {:relative_mouse, %{}}
      mode = Descriptor.pointer_mode(report_desc) -> {:mouse, %{mode: mode}}
      true -> nil
    end
  end

  # One of this module's by its default name, whatever its descriptor.
  defp default_hid("mouse"), do: {:mouse, %{mode: nil}}
  defp default_hid("keyboard"), do: {:keyboard, %{}}
  defp default_hid("relative_mouse"), do: {:relative_mouse, %{}}
  defp default_hid(_name), do: nil

  defp audio_instance(dir, name) do
    directions =
      for direction <- @audio, into: %{}, do: {direction, audio_direction(dir, direction)}

    if Enum.any?(directions, fn {_direction, format} -> format end),
      do: [Map.merge(%{kind: :audio, name: name}, directions)],
      else: []
  end

  defp audio_direction(dir, function) do
    read = fn attribute -> File.read(Path.join(dir, @prefix[function] <> attribute)) end

    with {:ok, mask} <- read.("chmask"),
         {mask, _rest} when mask > 0 <- Integer.parse(mask),
         {:ok, rates} <- read.("srate"),
         {:ok, ssize} <- read.("ssize"),
         {ssize, _rest} <- Integer.parse(ssize) do
      rates = rates |> String.split([",", "\n"], trim: true) |> Enum.map(&String.to_integer/1)
      %{channels: popcount(mask), rates: rates, sample_bits: ssize * 8}
    else
      _ -> nil
    end
  end

  defp count_luns(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.count(names, &String.starts_with?(&1, "lun."))
      {:error, _reason} -> 0
    end
  end

  defp popcount(0), do: 0
  defp popcount(n), do: (n &&& 1) + popcount(n >>> 1)

  defp dir_name(%{kind: kind, name: name}), do: "#{@types[kind]}.#{name}"
  defp dir(gadget, instance), do: Path.join([gadget, "functions", dir_name(instance)])
  defp link_path(gadget, instance), do: Path.join([gadget, @config, dir_name(instance)])

  defp add(state, instance, kept) do
    dir = dir(state.gadget, instance)

    with :ok <- File.mkdir_p(dir),
         :ok <- setup(dir, instance, state),
         :ok <- restore_luns(dir, instance, kept[instance.name]) do
      File.ln_s(dir, link_path(state.gadget, instance))
    end
  end

  defp setup(dir, %{kind: :keyboard}, _state), do: setup_hid(dir, Descriptor.keyboard())
  defp setup(dir, %{kind: :mouse, mode: mode}, _state), do: setup_hid(dir, Descriptor.mouse(mode))

  defp setup(dir, %{kind: :relative_mouse}, _state),
    do: setup_hid(dir, Descriptor.relative_mouse())

  # configfs makes lun.0 with the function, the others with mkdir; mkdir_p
  # is for plain directories.
  defp setup(dir, %{kind: :storage, luns: luns}, state) do
    inquiry =
      case state.names[:storage] do
        {vendor, product, revision} -> [inquiry_string: inquiry(vendor, product, revision)]
        nil -> []
      end

    each(0..(luns - 1), fn number ->
      lun = Path.join(dir, "lun.#{number}")

      with :ok <- File.mkdir_p(lun),
           do: write_all(lun, [removable: "1", cdrom: "0", ro: "0", nofua: "0"] ++ inquiry)
    end)
  end

  # A network function's addresses stay the same across boots: the
  # system's network takes the default ones, another network its own, made
  # from the gadget's serial number and its name.
  defp setup(dir, %{kind: :network, name: name}, state) do
    addresses =
      if "ncm.#{name}" == state.network.function and state.network.default_addresses,
        do: state.network.default_addresses,
        else: derived_addresses(state.gadget, name)

    write_all(dir, dev_addr: addresses.device_address, host_addr: addresses.host_address)
  end

  defp setup(dir, %{kind: :audio} = audio, state) do
    with :ok <- write_all(dir, direction(:microphone, audio.microphone, state.max_packet)),
         :ok <- write_all(dir, direction(:speaker, audio.speaker, state.max_packet)),
         # No feedback endpoint: the speaker follows the computer's clock.
         :ok <- write_all(dir, c_sync: "adaptive") do
      # Where the kernel takes them: no interrupt endpoint, which the
      # controls do without and the functions need, and the names.
      write_existing(dir, [int_ep_present: "0"] ++ audio_names(state.names))
    end
  end

  defp derived_addresses(gadget, name) do
    serial =
      case File.read(Path.join(gadget, "strings/0x409/serialnumber")) do
        {:ok, serial} -> String.trim(serial)
        {:error, _reason} -> ""
      end

    address = fn role ->
      <<first, rest::binary-size(5), _::binary>> =
        :crypto.hash(:sha256, [serial, 0, name, 0, role])

      # Locally administered, unicast.
      format_address(<<(first &&& 0xFC) ||| 0x02, rest::binary>>)
    end

    %{device_address: address.("device"), host_address: address.("host")}
  end

  # The media of a storage function's LUNs, to write back when it changes.
  defp lun_settings(dir) do
    for number <- 0..(count_luns(dir) - 1)//1, into: %{} do
      lun = Path.join(dir, "lun.#{number}")

      settings =
        for name <- @lun_settings,
            {:ok, value} <- [File.read(Path.join(lun, Atom.to_string(name)))],
            do: {name, String.trim_trailing(value, "\n")}

      {number, settings}
    end
  end

  defp restore_luns(_dir, _instance, nil), do: :ok

  # Every kernel has a LUN's file; the other settings where it has them.
  defp restore_luns(dir, %{luns: luns}, kept) do
    each(Enum.filter(kept, fn {number, _settings} -> number < luns end), fn {number, settings} ->
      lun = Path.join(dir, "lun.#{number}")
      {file, others} = Keyword.split(settings, [:file])

      with :ok <- write_existing(lun, others),
           do: write_all(lun, Enum.reject(file, &match?({:file, ""}, &1)))
    end)
  end

  # SCSI INQUIRY: vendor (8), product (16), revision (4), padded.
  defp inquiry(vendor, product, revision),
    do: field(vendor, 8) <> field(product, 16) <> field(revision, 4)

  defp field(text, size), do: text |> String.pad_trailing(size) |> binary_part(0, size)

  defp audio_names(names) do
    Enum.flat_map(names, fn
      {:audio, name} -> [function_name: name]
      {:speaker, name} -> [c_alt0_name: name, c_alt1_name: name]
      {:microphone, name} -> [p_alt0_name: name, p_alt1_name: name]
      {:storage, _name} -> []
    end)
  end

  # A direction left out has no channels.
  defp direction(function, nil, _max_packet), do: [{attribute(function, "chmask"), "0"}]

  defp direction(function, format, max_packet) do
    [
      {attribute(function, "chmask"), Integer.to_string(@channel_masks[format.channels])},
      {attribute(function, "srate"), Enum.map_join(format.rates, ",", &Integer.to_string/1)},
      {attribute(function, "ssize"), Integer.to_string(div(format.sample_bits, 8))},
      {attribute(function, "hs_bint"), Integer.to_string(interval(function, format, max_packet))}
    ]
  end

  defp attribute(function, name), do: String.to_atom(@prefix[function] <> name)

  # No OUT endpoints, as with the stock firmware: the keyboard's LEDs come
  # through the control endpoint, and the functions need the endpoints.
  defp setup_hid(dir, descriptor) do
    with :ok <-
           write_all(dir,
             protocol: Integer.to_string(descriptor.protocol),
             subclass: Integer.to_string(descriptor.subclass),
             report_length: Integer.to_string(descriptor.report_length),
             report_desc: descriptor.report_desc
           ) do
      write_existing(dir, no_out_endpoint: "1")
    end
  end

  # configfs removes a function's attributes with it, its extra LUNs first.
  defp remove(state, instance) do
    dir = dir(state.gadget, instance)

    extra_luns =
      for number <- (count_luns(dir) - 1)..1//-1, do: Path.join(dir, "lun.#{number}")

    with :ok <- File.rm(link_path(state.gadget, instance)),
         :ok <- each(extra_luns, state.rmdir) do
      state.rmdir.(dir)
    end
  end

  defp bound_udc(gadget) do
    case File.read(Path.join(gadget, "UDC")) do
      {:ok, name} -> String.trim(name)
      {:error, _reason} -> ""
    end
  end

  defp unbind(_gadget, ""), do: :ok
  defp unbind(gadget, _udc), do: File.write(Path.join(gadget, "UDC"), "\n")

  defp bind(state, "") do
    case File.ls(state.udc_class) do
      {:ok, [udc | _others]} -> bind(state, udc)
      _ -> {:error, :no_udc}
    end
  end

  defp bind(state, udc), do: File.write(Path.join(state.gadget, "UDC"), udc)

  defp write_all(dir, attributes) do
    each(attributes, fn {name, value} ->
      File.write(Path.join(dir, Atom.to_string(name)), value)
    end)
  end

  defp write_existing(dir, attributes) do
    attributes
    |> Enum.filter(fn {name, _value} -> File.exists?(Path.join(dir, Atom.to_string(name))) end)
    |> then(&write_all(dir, &1))
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {item, reason}}}
      end
    end)
  end

  # The functions asked for, in order: the audio directions of a name are
  # one function, with their formats.
  defp normalize(specs, max_packet) do
    with {:ok, entries} <- collect(specs, &entry(&1, max_packet)),
         {:ok, instances} <- merge_audio(entries),
         :ok <- unique(instances) do
      {:ok, sort(instances)}
    end
  end

  defp entry(kind, max_packet) when is_atom(kind) and is_map_key(@types, kind) and kind != :audio,
    do: entry({kind, []}, max_packet)

  defp entry({kind, opts}, max_packet)
       when (is_list(opts) and kind in [:mouse | @audio]) or
              (kind in [:keyboard, :relative_mouse, :storage, :network] and is_list(opts)) do
    {name, opts} = Keyword.pop(opts, :name, @default_names[kind])

    if valid_name?(name),
      do: kind_entry(kind, name, opts, max_packet),
      else: {:error, {:invalid_name, kind, name}}
  end

  defp entry(other, _max_packet), do: {:error, {:unknown_function, other}}

  defp kind_entry(:mouse, name, opts, _max_packet) do
    case Keyword.pop(opts, :mode, :absolute) do
      {mode, []} when mode in [:absolute, :stylus, :touch] ->
        {:ok, %{kind: :mouse, name: name, mode: mode}}

      {mode, []} ->
        {:error, {:invalid_mode, :mouse, mode}}

      {_mode, rest} ->
        {:error, {:unknown_options, :mouse, Keyword.keys(rest)}}
    end
  end

  defp kind_entry(:storage, name, opts, _max_packet) do
    case Keyword.pop(opts, :luns, 1) do
      {luns, []} when luns in 1..@max_luns ->
        {:ok, %{kind: :storage, name: name, luns: luns}}

      {luns, []} ->
        {:error, {:invalid_luns, luns}}

      {_drives, rest} ->
        {:error, {:unknown_options, :storage, Keyword.keys(rest)}}
    end
  end

  defp kind_entry(kind, name, opts, max_packet) when kind in @audio do
    with {:ok, format} <- audio_format(kind, opts, max_packet),
         do: {:ok, %{kind: kind, name: name, format: format}}
  end

  defp kind_entry(kind, name, [], _max_packet), do: {:ok, %{kind: kind, name: name}}

  defp kind_entry(kind, _name, opts, _max_packet),
    do: {:error, {:unknown_options, kind, Keyword.keys(opts)}}

  # configfs takes names of letters, digits, "_" and "-".
  defp valid_name?(name) do
    is_binary(name) and byte_size(name) in 1..32 and
      String.match?(name, ~r/^[A-Za-z0-9_-]+$/)
  end

  # A microphone and a speaker of one name are the two directions of a USB
  # Audio Class 2 function.
  defp merge_audio(entries) do
    {directions, others} = Enum.split_with(entries, &(&1.kind in @audio))

    Enum.reduce_while(directions, {:ok, %{}}, fn %{kind: kind, name: name, format: format},
                                                 {:ok, acc} ->
      unit = Map.get(acc, name, %{kind: :audio, name: name, microphone: nil, speaker: nil})

      if unit[kind],
        do: {:halt, {:error, {:duplicate_function, kind}}},
        else: {:cont, {:ok, Map.put(acc, name, Map.put(unit, kind, format))}}
    end)
    |> case do
      {:ok, units} -> {:ok, others ++ Map.values(units)}
      error -> error
    end
  end

  defp unique(instances) do
    names = Enum.map(instances, &dir_name/1)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dir | _rest] -> {:error, {:duplicate_function, duplicate_kind(instances, dir)}}
    end
  end

  defp duplicate_kind(instances, dir) do
    case Enum.find(instances, &(dir_name(&1) == dir)) do
      %{kind: kind, name: name} -> if name == @default_names[kind], do: kind, else: {kind, name}
    end
  end

  # The endpoints functions take, and whether the controller has them.
  defp count_endpoints(instances) do
    Enum.reduce(instances, %{in: 0, out: 0}, fn instance, acc ->
      {ins, outs} = endpoint_cost(instance)
      %{in: acc.in + ins, out: acc.out + outs}
    end)
  end

  defp endpoint_cost(%{kind: kind}) when kind in @hid, do: {1, 0}
  defp endpoint_cost(%{kind: :storage}), do: {1, 1}
  defp endpoint_cost(%{kind: :network}), do: {2, 1}

  defp endpoint_cost(%{kind: :audio} = audio),
    do: {if(audio.microphone, do: 1, else: 0), if(audio.speaker, do: 1, else: 0)}

  defp check_endpoints(_instances, nil), do: :ok

  defp check_endpoints(instances, have) do
    need = count_endpoints(instances)

    if need.in <= have.in and need.out <= have.out,
      do: :ok,
      else: {:error, {:not_enough_endpoints, %{need: need, have: have}}}
  end

  defp audio_format(function, opts, max_packet) do
    format = %{
      channels: Keyword.get(opts, :channels, 2),
      rates: opts |> Keyword.get(:rates, [48_000]) |> uniq_rates(),
      sample_bits: Keyword.get(opts, :sample_bits, 16)
    }

    cond do
      Keyword.keys(opts) -- [:channels, :rates, :sample_bits] != [] ->
        {:error, {:unknown_options, function, Keyword.keys(opts)}}

      not Map.has_key?(@channel_masks, format.channels) ->
        {:error, {:invalid_channels, function, format.channels}}

      not valid_rates?(format.rates) ->
        {:error, {:invalid_rates, function, Keyword.get(opts, :rates)}}

      format.sample_bits not in [16, 24, 32] ->
        {:error, {:invalid_sample_bits, function, format.sample_bits}}

      interval(function, format, max_packet) == nil ->
        {:error, {:too_much_bandwidth, function, format}}

      true ->
        {:ok, format}
    end
  end

  defp uniq_rates(rates) when is_list(rates), do: Enum.uniq(rates)
  defp uniq_rates(rates), do: rates

  defp valid_rates?(rates) do
    is_list(rates) and length(rates) in 1..@max_rates and
      Enum.all?(rates, &(is_integer(&1) and &1 in 8_000..384_000))
  end

  # High speed sends a packet each 125 µs × 2^(interval - 1): the longest
  # interval whose packets the controller takes, nil for none.
  defp interval(function, format, max_packet) do
    Enum.find(4..1//-1, &(packet(function, format, &1) <= max_packet[function]))
  end

  # The bytes of a packet, as f_uac2 reckons them: the microphone may run
  # 0.5 % fast, and the speaker's packets have room for a frame more.
  defp packet(function, format, interval) do
    frame = format.channels * div(format.sample_bits, 8)
    per_second = div(8000, 1 <<< (interval - 1))
    rate = Enum.max(format.rates)

    case function do
      :microphone -> frame * ceil_div(div(rate * 1005, 1000), per_second)
      :speaker -> frame * (ceil_div(rate, per_second) + 1)
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

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

  defp check_gadget(gadget) do
    if File.dir?(gadget), do: :ok, else: {:error, {:no_gadget, gadget}}
  end
end

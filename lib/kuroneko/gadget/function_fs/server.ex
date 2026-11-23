defmodule Kuroneko.Gadget.FunctionFS.Server do
  @moduledoc false

  use GenServer, restart: :temporary

  require Logger

  alias Kuroneko.Gadget.FunctionFS.EP0

  @registry Kuroneko.Gadget.FunctionFS.Registry
  @supervisor Kuroneko.Gadget.FunctionFS.Supervisor
  @reply_timeout 5_000
  @quit_timeout 2_000
  @max_transfer 1_048_576
  @errnos %{
    1 => :eperm,
    2 => :enoent,
    5 => :eio,
    11 => :eagain,
    12 => :enomem,
    16 => :ebusy,
    19 => :enodev,
    22 => :einval,
    32 => :epipe,
    43 => :eidrm,
    71 => :eproto,
    77 => :ebadfd,
    104 => :econnreset,
    108 => :eshutdown,
    110 => :etimedout,
    125 => :ecanceled
  }

  @spec ready(module(), Path.t(), term()) :: :ok | {:error, term()}
  def ready(module, dir, settings) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {module, dir, settings}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec teardown(Path.t()) :: :ok | {:error, term()}
  def teardown(dir) do
    Enum.each(Registry.lookup(@registry, dir), fn {pid, _value} ->
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end)

    unmount(dir)
  end

  @spec start_link({module(), Path.t(), term()}) :: GenServer.on_start()
  def start_link({_module, dir, _settings} = args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, dir}})

  @impl GenServer
  def init({module, dir, settings}) do
    # Without trapping exits, terminate/2 does not run when the supervisor
    # stops the process, and the program would outlive the unmount.
    Process.flag(:trap_exit, true)

    with {:ok, ep0} <- EP0.encode(module.interfaces(settings)),
         {:ok, program} <- program(),
         :ok <- mount(dir),
         port = open(program, mount_point(dir)),
         :ok <- start(port, ep0),
         {:ok, user} <- module.init(settings) do
      directions = ep0.directions |> Enum.with_index(1) |> Map.new(fn {d, n} -> {n, d} end)
      {:ok, %{module: module, port: port, directions: directions, user: user}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:write, endpoint, data}, state) do
    if state.directions[endpoint] == :in and byte_size(data) <= @max_transfer do
      Port.command(state.port, [?W, endpoint, data])
      {:noreply, state}
    else
      {:noreply, dispatch({:error, endpoint, :einval}, state)}
    end
  end

  def handle_cast({:read, endpoint, size}, state) do
    if state.directions[endpoint] == :out and size <= @max_transfer do
      Port.command(state.port, [?R, endpoint, <<size::32>>])
      {:noreply, state}
    else
      {:noreply, dispatch({:error, endpoint, :einval}, state)}
    end
  end

  def handle_cast({:answer, data}, state) do
    Port.command(state.port, [?C, data])
    {:noreply, state}
  end

  def handle_cast(:stall, state) do
    Port.command(state.port, "X")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, <<?r, ?E, status::signed-32>>}}, %{port: port} = state),
    do: {:stop, {:ep0, errno(-status)}, state}

  def handle_info({port, {:data, packet}}, %{port: port} = state),
    do: {:noreply, packet |> events() |> Enum.reduce(state, &dispatch/2)}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:exit_status, status}, %{state | port: nil}}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  def handle_info(message, state) do
    if function_exported?(state.module, :handle_info, 2),
      do: {:noreply, callback(state, :handle_info, [message, state.user])},
      else: {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.command(port, "Q")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @quit_timeout -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp start(port, ep0) do
    directions = Enum.map(ep0.directions, &if(&1 == :in, do: 1, else: 0))

    with :ok <- command(port, [?D, ep0.descriptors], :descriptors),
         :ok <- command(port, [?S, ep0.strings], :strings) do
      command(port, [?O, length(directions) | directions], :endpoints)
    end
  end

  defp command(port, packet, step) do
    Port.command(port, packet)

    receive do
      {^port, {:data, <<?r, ?E, status::signed-32>>}} -> {:error, {:ep0, errno(-status)}}
      {^port, {:data, <<?r, _kind, status::signed-32>>}} when status >= 0 -> :ok
      {^port, {:data, <<?r, _kind, status::signed-32>>}} -> {:error, {step, errno(-status)}}
      {^port, {:exit_status, status}} -> {:error, {:exit_status, status}}
    after
      @reply_timeout -> {:error, {step, :timeout}}
    end
  end

  defp events(<<?E, event::binary-size(12)>>), do: EP0.events(event)
  defp events(<<?d, endpoint, data::binary>>), do: [{:data, endpoint, data}]

  defp events(<<?w, endpoint, bytes::signed-32>>) when bytes >= 0,
    do: [{:written, endpoint, bytes}]

  defp events(<<?w, endpoint, status::signed-32>>), do: [{:error, endpoint, errno(-status)}]
  defp events(<<?e, endpoint, status::signed-32>>), do: [{:error, endpoint, errno(-status)}]
  defp events(<<?c, data::binary>>), do: [{:control_data, data}]

  defp events(<<?r, kind, status::signed-32>>) when kind in [?C, ?X] and status < 0,
    do: [{:control_error, errno(-status)}]

  defp events(<<?r, _kind, _status::signed-32>>), do: []

  defp dispatch(event, state), do: callback(state, :handle_event, [event, state.user])

  defp callback(state, name, args) do
    {:noreply, user} = apply(state.module, name, args)
    %{state | user: user}
  rescue
    exception ->
      Logger.error(
        "kuroneko_gadget: #{inspect(state.module)}.#{name}/#{length(args)} failed\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      state
  end

  defp program do
    path = Application.app_dir(:kuroneko_gadget, ["priv", "kuroneko_ffs"])
    if File.exists?(path), do: {:ok, path}, else: {:error, {:no_program, path}}
  end

  defp open(program, mount_point) do
    Port.open({:spawn_executable, program}, [
      :binary,
      :exit_status,
      {:packet, 4},
      args: [mount_point]
    ])
  end

  defp instance(dir) do
    "ffs." <> instance = Path.basename(dir)
    instance
  end

  defp mount_point(dir), do: "/dev/ffs-" <> instance(dir)

  # Without no_disconnect, closing ep0 while the gadget is on the bus takes
  # the whole gadget off the bus.
  defp mount(dir) do
    target = mount_point(dir)

    if mounted?(target) do
      :ok
    else
      with :ok <- File.mkdir_p(target) do
        run("mount", ["-t", "functionfs", "-o", "no_disconnect=1", instance(dir), target])
      end
    end
  end

  defp unmount(dir) do
    target = mount_point(dir)

    if mounted?(target) do
      with :ok <- run("umount", [target]), do: File.rmdir(target)
    else
      :ok
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

  defp run(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {command, status, String.trim(output)}}
    end
  end

  defp errno(number), do: Map.get(@errnos, number, {:errno, number})
end

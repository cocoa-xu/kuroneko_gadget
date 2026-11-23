defmodule Kuroneko.Gadget.FunctionFS.Server do
  @moduledoc false
  # The process of a FunctionFS function: it mounts the function's
  # FunctionFS, runs kuroneko_ffs on it (see c_src/kuroneko_ffs.c for the
  # packets), and calls the module's callbacks.
  use GenServer, restart: :temporary

  require Logger

  alias Kuroneko.Gadget.FunctionFS

  @reply_ms 5_000
  @quit_ms 2_000
  @max_transfer 1_048_576

  # The kernel's error numbers, the same on every Linux architecture.
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

  @spec start_link({module(), Path.t(), term()}) :: GenServer.on_start()
  def start_link({_module, dir, _settings} = args) do
    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {Kuroneko.Gadget.FunctionFS.Registry, dir}}
    )
  end

  @impl GenServer
  def init({module, dir, settings}) do
    # The program is told to quit when the function goes.
    Process.flag(:trap_exit, true)

    with {:ok, layout} <- layout(module, settings),
         {:ok, program} <- FunctionFS.program(),
         :ok <- FunctionFS.mount(dir),
         {:ok, port} <- open(program, FunctionFS.mount_dir(dir)) do
      state = %{
        module: module,
        port: port,
        endpoints: Map.new(layout.endpoints, &{&1.number, &1.direction}),
        user: nil
      }

      start(state, layout, settings)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start(state, layout, settings) do
    directions =
      for e <- layout.endpoints, into: <<>>, do: <<if(e.direction == :in, do: 1, else: 0)>>

    with :ok <- command(state.port, ?D, layout.descriptors),
         :ok <- command(state.port, ?S, layout.strings),
         :ok <- command(state.port, ?O, <<length(layout.endpoints), directions::binary>>),
         {:ok, user} <- init_callback(state.module, settings) do
      {:ok, %{state | user: user}}
    else
      {:error, reason} ->
        quit(state.port)
        {:stop, reason}
    end
  end

  defp layout(module, settings) do
    FunctionFS.layout(module.interfaces(settings))
  rescue
    exception -> {:error, {module, :interfaces, Exception.message(exception)}}
  end

  defp init_callback(module, settings) do
    if function_exported?(module, :init, 1) do
      case callback(module, :init, [settings]) do
        {:ok, user} -> {:ok, user}
        {:error, reason} -> {:error, reason}
        {:failed, reason} -> {:error, reason}
        other -> {:error, {module, :init, {:bad_return, other}}}
      end
    else
      {:ok, settings}
    end
  end

  defp open(program, dir) do
    {:ok,
     Port.open({:spawn_executable, program}, [
       :binary,
       :exit_status,
       :use_stdio,
       {:packet, 4},
       args: [dir]
     ])}
  rescue
    exception -> {:error, {:port, Exception.message(exception)}}
  end

  # A command of the start, and the program's answer to it.
  defp command(port, kind, data) do
    Port.command(port, [kind, data])

    receive do
      {^port, {:data, <<?r, ^kind, status::signed-32>>}} when status >= 0 ->
        :ok

      {^port, {:data, <<?r, ^kind, status::signed-32>>}} ->
        {:error, {kind_name(kind), errno(-status)}}

      {^port, {:data, <<?r, ?E, status::signed-32>>}} ->
        {:error, {:ep0, errno(-status)}}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      @reply_ms -> {:error, {kind_name(kind), :timeout}}
    end
  end

  defp kind_name(?D), do: :descriptors
  defp kind_name(?S), do: :strings
  defp kind_name(?O), do: :endpoints

  @impl GenServer
  def handle_cast({:write, endpoint, data}, state) do
    if state.endpoints[endpoint] == :in and is_binary(data) and byte_size(data) <= @max_transfer do
      Port.command(state.port, [?W, endpoint, data])
      {:noreply, state}
    else
      {:noreply, dispatch({:error, endpoint, :einval}, state)}
    end
  end

  def handle_cast({:read, endpoint, size}, state) do
    if state.endpoints[endpoint] == :out and is_integer(size) and size in 0..@max_transfer do
      Port.command(state.port, [?R, endpoint, <<size::32>>])
      {:noreply, state}
    else
      {:noreply, dispatch({:error, endpoint, :einval}, state)}
    end
  end

  def handle_cast({:answer, data}, state) when is_binary(data) do
    Port.command(state.port, [?C, data])
    {:noreply, state}
  end

  def handle_cast({:answer, _data}, state),
    do: {:noreply, dispatch({:control_error, :einval}, state)}

  def handle_cast(:stall, state) do
    Port.command(state.port, [?X])
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    case decode(packet) do
      {:stop, reason} -> {:stop, reason, state}
      events -> {:noreply, Enum.reduce(events, state, &dispatch/2)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:exit_status, status}, %{state | port: nil}}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    if function_exported?(state.module, :handle_info, 2),
      do: {:noreply, reply(callback(state.module, :handle_info, [message, state.user]), state)},
      else: {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port), do: quit(port)
  def terminate(_reason, _state), do: :ok

  defp quit(port) do
    Port.command(port, [?Q])

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @quit_ms -> Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp decode(<<?E, event::binary-size(12)>>), do: FunctionFS.events(event)
  defp decode(<<?d, endpoint, data::binary>>), do: [{:data, endpoint, data}]

  defp decode(<<?w, endpoint, result::signed-32>>) when result >= 0,
    do: [{:written, endpoint, result}]

  defp decode(<<?w, endpoint, status::signed-32>>), do: [{:error, endpoint, errno(-status)}]
  defp decode(<<?e, endpoint, status::signed-32>>), do: [{:error, endpoint, errno(-status)}]
  defp decode(<<?c, data::binary>>), do: [{:control_data, data}]
  defp decode(<<?r, ?E, status::signed-32>>), do: {:stop, {:ep0, errno(-status)}}

  defp decode(<<?r, kind, status::signed-32>>) when kind in [?C, ?X] and status < 0,
    do: [{:control_error, errno(-status)}]

  defp decode(_packet), do: []

  defp dispatch(event, state) do
    if function_exported?(state.module, :handle_event, 2) do
      reply(callback(state.module, :handle_event, [event, state.user]), state)
    else
      _ = FunctionFS.default_event(event, state.user)
      state
    end
  end

  defp reply({:noreply, user}, state), do: %{state | user: user}
  defp reply({:failed, _reason}, state), do: state

  defp reply(other, state) do
    Logger.error("kuroneko_gadget: #{inspect(state.module)} returned #{inspect(other)}")
    state
  end

  # A callback's exceptions and exits, logged: the function goes on.
  defp callback(module, name, args) do
    apply(module, name, args)
  rescue
    exception ->
      Logger.error(
        "kuroneko_gadget: #{inspect(module)}.#{name} failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:failed, {module, name, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.error(
        "kuroneko_gadget: #{inspect(module)}.#{name} failed: #{inspect({kind, reason})}"
      )

      {:failed, {module, name, {kind, reason}}}
  end

  defp errno(number), do: Map.get(@errnos, number, {:errno, number})
end

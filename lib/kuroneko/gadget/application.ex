defmodule Kuroneko.Gadget.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Kuroneko.Gadget.FunctionFS.Registry},
      {DynamicSupervisor, name: Kuroneko.Gadget.FunctionFS.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Kuroneko.Gadget.Supervisor)
  end
end

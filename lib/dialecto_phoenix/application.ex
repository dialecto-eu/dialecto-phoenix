defmodule DialectoPhoenix.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([DialectoPhoenix.Store],
      strategy: :one_for_one,
      name: DialectoPhoenix.Supervisor
    )
  end
end

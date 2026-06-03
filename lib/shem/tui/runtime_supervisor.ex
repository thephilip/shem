defmodule Shem.TUI.RuntimeSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Ratatouille.Runtime.Supervisor,
       runtime: [app: Shem.TUI.App, quit_events: [{:key, 3}, {:ch, ?q}]]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

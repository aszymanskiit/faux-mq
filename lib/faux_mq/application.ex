defmodule FauxMQ.Application do
  @moduledoc """
  OTP application module for FauxMQ.

  This application itself does not start any TCP servers automatically.
  In tests you typically start individual FauxMQ server instances via
  `FauxMQ.start_link/1` or as children in your supervision tree using
  `FauxMQ.child_spec/1`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: FauxMQ.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FauxMQ.Supervisor)
  end
end

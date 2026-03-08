defmodule FauxMQ.Protocol.Frame do
  @moduledoc """
  AMQP 0-9-1 frame representation.

  Implements encoding and decoding of generic AMQP frames as described in
  the specification. Method/content header/body and heartbeat frames are
  all modelled using this structure.
  """

  @type frame_type :: :method | :header | :body | :heartbeat

  @type t :: %__MODULE__{
          type: frame_type(),
          channel: non_neg_integer(),
          payload: binary()
        }

  defstruct [:type, :channel, :payload]
end

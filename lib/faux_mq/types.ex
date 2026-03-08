defmodule FauxMQ.Types do
  @moduledoc """
  Shared types for FauxMQ's public API and internal components.

  The goal of this module is to keep the main API dialyzer-friendly while
  avoiding circular dependencies between modules.
  """

  @typedoc """
  Identifies an incoming AMQP call for the mock/expectation engine.
  """
  @type call_context :: %{
          connection_id: non_neg_integer(),
          channel_id: non_neg_integer(),
          class_id: non_neg_integer(),
          method_id: non_neg_integer(),
          method_name: atom() | nil,
          args: binary()
        }

  @typedoc """
  Matching specification for a rule. All fields are optional and combined with AND.
  """
  @type match_spec ::
          %{
            optional(:connection_id) => non_neg_integer() | :any,
            optional(:channel_id) => non_neg_integer() | :any,
            optional(:class_id) => non_neg_integer(),
            optional(:method_id) => non_neg_integer(),
            optional(:method_name) => atom(),
            optional(:predicate) => (call_context() -> boolean())
          }

  @typedoc """
  Actions that a mock rule can trigger.
  """
  @type action_spec ::
          :no_reply
          | {:reply, reply_action()}
          | {:sequence, [action_spec()]}
          | {:delay, non_neg_integer(), action_spec()}
          | :close_connection
          | :close_channel
          | :protocol_error

  @typedoc """
  Reply actions at frame level or method-level convenience.
  """
  @type reply_action ::
          {:frames, [frame_spec()]}
          | {:method, non_neg_integer(), non_neg_integer(), binary()}

  @typedoc """
  Specification of a server-initiated frame.
  """
  @type frame_spec :: %{
          type: :method | :header | :body | :heartbeat,
          channel: non_neg_integer(),
          payload: binary()
        }

  @typedoc """
  Specification of a pushed delivery.
  """
  @type push_delivery_spec :: %{
          channel_id: non_neg_integer(),
          consumer_tag: binary(),
          exchange: binary(),
          routing_key: binary(),
          payload: binary(),
          delivery_tag: non_neg_integer(),
          redelivered: boolean()
        }

  @typedoc """
  Specification of a pushed frame from test code.
  """
  @type push_frame_spec :: frame_spec()

  @typedoc """
  Call record stored for assertions in tests.
  """
  @type call_record :: %{
          context: call_context(),
          timestamp: integer()
        }
end

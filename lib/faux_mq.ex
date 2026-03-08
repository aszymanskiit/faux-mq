defmodule FauxMQ do
  @moduledoc """
  FauxMQ - a controllable dummy AMQP 0-9-1 broker for integration testing.

  FauxMQ runs a real TCP server that speaks the AMQP 0-9-1 protocol and allows
  you to control broker behaviour from Elixir tests. It is designed for testing
  ejabberd/XMPP and other systems that use AMQP for backend integration.

  Typical usage:

    * start a FauxMQ server on a random port
    * inject its `endpoint/1` into your system-under-test configuration
    * define expectations and stubs using `stub/3` and `expect/3`
    * run assertions against collected call history via `calls/1`

  This module exposes the main public API. All functions are dialyzer-friendly
  and documented with types.
  """

  alias FauxMQ.{MockServer, Server, Types}

  @type server :: pid()

  @doc """
  Starts a FauxMQ server process linked to the caller.

  Options:

    * `:host` - IP tuple (default: application `:default_host`)  
    * `:port` - TCP port or `0` for random free port (default: application `:default_port`)  
    * `:name` - optional atom name to register the server in `Registry`  
    * `:mode` - `:stateful` or `:scripted` (default: `:mixed`, i.e. mocks first, then stateful)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Server.start_link(opts)
  end

  @doc """
  Returns a child spec for use in supervision trees.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc """
  Gracefully stops a FauxMQ server.
  """
  @spec stop(server()) :: :ok
  def stop(server) do
    Server.stop(server)
  end

  @doc """
  Returns the TCP port that the server is listening on.
  """
  @spec port(server()) :: :inet.port_number()
  def port(server) do
    Server.port(server)
  end

  @doc """
  Returns the host IP tuple that the server is bound to.
  """
  @spec host(server()) :: :inet.ip_address()
  def host(server) do
    Server.host(server)
  end

  @doc """
  Returns a convenient endpoint map `%{host: host, port: port}`.
  """
  @spec endpoint(server()) :: %{host: :inet.ip_address(), port: :inet.port_number()}
  def endpoint(server) do
    %{host: host(server), port: port(server)}
  end

  @doc """
  Registers a stub rule on the given server.

  The simple form `stub(server, match, action)` creates a rule that will be
  applied whenever an incoming AMQP method matches the given `match` pattern.
  The `action` controls how the server responds.

  See `FauxMQ.Types.match_spec/0` and `FauxMQ.Types.action_spec/0` for details.
  """
  @spec stub(server(), Types.match_spec(), Types.action_spec()) :: :ok
  def stub(server, match, action) do
    MockServer.stub(server, match, action)
  end

  @doc """
  Registers an expectation on the given server.

  Expectations are like stubs but are intended for asserting that certain calls
  happened a given number of times. The `times` argument controls how many
  times the rule may fire before it is removed.
  """
  @spec expect(server(), Types.match_spec(), non_neg_integer(), Types.action_spec()) :: :ok
  def expect(server, match, times, action) when times >= 0 do
    MockServer.expect(server, match, times, action)
  end

  @doc """
  Injects a delivery into the server for the specified logical queue/consumer.

  This is useful for tests that want to drive messages to consumers without
  going through `basic.publish` semantics.
  """
  @spec push_delivery(server(), Types.push_delivery_spec()) :: :ok
  def push_delivery(server, delivery) do
    MockServer.push_delivery(server, delivery)
  end

  @doc """
  Injects a raw AMQP frame-level action initiated by the server.
  """
  @spec push_frame(server(), Types.push_frame_spec()) :: :ok
  def push_frame(server, frame_spec) do
    MockServer.push_frame(server, frame_spec)
  end

  @doc """
  Returns the history of handled AMQP calls for the given server.
  """
  @spec calls(server()) :: [Types.call_record()]
  def calls(server) do
    MockServer.calls(server)
  end

  @doc """
  Resets all mock rules and state for the given server.

  This does not close existing TCP connections but clears broker state and
  mock definitions. Intended to be called between tests.
  """
  @spec reset!(server()) :: :ok
  def reset!(server) do
    MockServer.reset!(server)
  end
end

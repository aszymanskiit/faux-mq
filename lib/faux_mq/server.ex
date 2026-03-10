defmodule FauxMQ.Server do
  @moduledoc """
  Top-level server process that owns the TCP listener and broker/mock state.

  A `FauxMQ.Server` instance is responsible for:

    * creating a `:gen_tcp` listening socket
    * accepting incoming connections and spawning `FauxMQ.Connection` processes
    * hosting the `FauxMQ.MockServer` per-instance process
    * in-memory queues for basic.publish / basic.get (default exchange only)
    * exposing basic metadata such as host and port
  """

  use GenServer

  alias FauxMQ.{MockServer, Protocol}

  @type stored_message :: %{
          body: binary(),
          exchange: binary(),
          routing_key: binary(),
          header_payload: binary() | nil
        }

  defstruct [
    :listener,
    :host,
    :port,
    :mock_server,
    next_connection_id: 1,
    connections: %{},
    queues: %{},
    bindings: %{},
    consumers: %{}
  ]

  @type t :: %__MODULE__{
          listener: port() | nil,
          host: :inet.ip_address(),
          port: :inet.port_number(),
          mock_server: pid(),
          next_connection_id: non_neg_integer(),
          connections: %{non_neg_integer() => pid()},
          queues: %{binary() => [stored_message()]},
          bindings: %{optional({binary(), binary()}) => binary()},
          consumers: %{
            optional(binary()) =>
              [
                %{
                  connection_id: non_neg_integer(),
                  channel_id: non_neg_integer(),
                  consumer_tag: binary(),
                  delivery_tag: non_neg_integer()
                }
              ]
          }
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec stop(pid()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  end

  @spec port(pid()) :: :inet.port_number()
  def port(server) do
    GenServer.call(server, :port)
  end

  @spec host(pid()) :: :inet.ip_address()
  def host(server) do
    GenServer.call(server, :host)
  end

  @impl true
  def init(opts) do
    # Use Application.get_env/3 instead of fetch_env!/2 to avoid relying on
    # newer Elixir runtime functions in environments where only the BEAM VM
    # is guaranteed. Fallbacks are generic and not domain-specific.
    host_default = Application.get_env(:faux_mq, :default_host, {127, 0, 0, 1})
    host = Keyword.get(opts, :host, host_default)

    # Allow callers to pass port: 0 as a sentinel meaning
    # "use the configured default_port" instead of asking the OS
    # for an ephemeral port. This is important for umbrella apps
    # that expect a stable port like 5672 (RabbitMQ default).
    raw_port = Keyword.get(opts, :port, :use_default)

    default_port = Application.get_env(:faux_mq, :default_port, 5672)

    port =
      case raw_port do
        0 -> default_port
        :use_default -> default_port
        other -> other
      end

    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: host
    ]

    # Try to bind to the requested port. If it is already in use (e.g. another
    # broker instance or RabbitMQ), fall back to an ephemeral port to keep the
    # dummy broker generic and robust in shared environments.
    listener =
      case :gen_tcp.listen(port, listen_opts) do
        {:ok, sock} ->
          sock

        {:error, :eaddrinuse} ->
          {:ok, sock} = :gen_tcp.listen(0, listen_opts)
          sock
      end

    {:ok, actual_port} = :inet.port(listener)

    {:ok, mock_server} = MockServer.start_link(self())

    state = %__MODULE__{
      listener: listener,
      host: host,
      port: actual_port,
      mock_server: mock_server,
      queues: %{},
      bindings: %{},
      connections: %{},
      consumers: %{},
      next_connection_id: 1
    }

    send(self(), :accept)

    {:ok, state}
  end

  @impl true
  @doc """
  Handles: `:port`, `:host`, `{:stub, ...}`, `{:expect, ...}`, `:calls`, `:reset`,
  `{:queue_ensure, name}`, `{:queue_purge, name}`, `{:queue_delete, name}`,
  `{:queue_bind, queue, exchange, routing_key}`,
  `{:register_consumer, queue, connection_id, channel_id, consumer_tag}`,
  `{:basic_publish, exchange, routing_key, payload}`, `{:basic_get, queue_name}`.
  """
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call(:host, _from, state) do
    {:reply, state.host, state}
  end

  def handle_call({:stub, match, action}, _from, state) do
    reply = GenServer.call(state.mock_server, {:stub, match, action})
    {:reply, reply, state}
  end

  def handle_call({:expect, match, count, action}, _from, state) do
    reply = GenServer.call(state.mock_server, {:expect, match, count, action})
    {:reply, reply, state}
  end

  def handle_call(:calls, _from, state) do
    reply = GenServer.call(state.mock_server, :calls)
    {:reply, reply, state}
  end

  def handle_call(:reset, _from, state) do
    reply = GenServer.call(state.mock_server, :reset)
    {:reply, reply, state}
  end

  def handle_call({:queue_ensure, queue_name}, _from, state) when is_binary(queue_name) do
    existing = Map.get(state.queues, queue_name, [])
    queues = Map.put_new(state.queues, queue_name, existing)
    {:reply, length(existing), %{state | queues: queues}}
  end

  def handle_call({:queue_purge, queue_name}, _from, state) when is_binary(queue_name) do
    {count, queues} =
      case state.queues do
        %{^queue_name => list} -> {length(list), %{state.queues | queue_name => []}}
        _ -> {0, state.queues}
      end

    {:reply, count, %{state | queues: queues}}
  end

  def handle_call({:queue_delete, queue_name}, _from, state) when is_binary(queue_name) do
    {count, queues} =
      case state.queues do
        %{^queue_name => list} -> {length(list), Map.delete(state.queues, queue_name)}
        _ -> {0, state.queues}
      end

    {:reply, count, %{state | queues: queues}}
  end

  def handle_call({:queue_bind, queue_name, exchange, routing_key}, _from, state)
      when is_binary(queue_name) and is_binary(exchange) and is_binary(routing_key) do
    # Ensure the queue exists and remember that this exchange/routing_key
    # pair should route to the given queue (RabbitMQ-style binding).
    queues = Map.put_new(state.queues, queue_name, [])
    bindings = Map.put(state.bindings, {exchange, routing_key}, queue_name)
    {:reply, :ok, %{state | queues: queues, bindings: bindings}}
  end

  def handle_call({:basic_publish, exchange, routing_key, payload, header_payload}, _from, state)
      when is_binary(payload) do
    queue_name = queue_for_publish(state, exchange, routing_key)

    message = %{
      body: payload,
      exchange: exchange,
      routing_key: routing_key,
      header_payload: header_payload
    }

    queues = append_to_queue(state.queues, queue_name, message)
    state = %{state | queues: queues}
    state = maybe_deliver_to_consumers(state, queue_name, message)
    {:reply, :ok, state}
  end

  # Backwards-compatible clause (no header payload).
  def handle_call({:basic_publish, exchange, routing_key, payload}, from, state)
      when is_binary(payload) do
    handle_call({:basic_publish, exchange, routing_key, payload, nil}, from, state)
  end

  def handle_call({:basic_get, queue_name}, _from, state) when is_binary(queue_name) do
    case state.queues do
      %{^queue_name => [head | rest]} ->
        queues = %{state.queues | queue_name => rest}
        {:reply, {:ok, head, length(rest)}, %{state | queues: queues}}

      _ ->
        {:reply, :empty, state}
    end
  end

  def handle_call(
        {:register_consumer, queue_name, connection_id, channel_id, consumer_tag},
        _from,
        state
      )
      when is_binary(queue_name) and is_integer(connection_id) and is_integer(channel_id) and
             is_binary(consumer_tag) do
    base = %{
      connection_id: connection_id,
      channel_id: channel_id,
      consumer_tag: consumer_tag,
      delivery_tag: 1
    }

    consumers_for_queue = Map.get(state.consumers, queue_name, [])
    consumers = Map.put(state.consumers, queue_name, consumers_for_queue ++ [base])

    # Ensure the queue exists so that basic.get on the same queue still works.
    queues = Map.put_new(state.queues, queue_name, [])

    state = %{state | consumers: consumers, queues: queues}

    # If there are already messages in the queue when a consumer registers,
    # deliver the first one immediately to mimic broker behaviour.
    state =
      case Map.get(state.queues, queue_name, []) do
        [message | _] -> maybe_deliver_to_consumers(state, queue_name, message)
        _ -> state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:push_delivery, delivery}, state) do
    GenServer.cast(state.mock_server, {:push_delivery, delivery})
    {:noreply, state}
  end

  def handle_cast({:push_frame, frame}, state) do
    GenServer.cast(state.mock_server, {:push_frame, frame})
    {:noreply, state}
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listener, 0) do
      {:ok, socket} ->
        connection_id = state.next_connection_id

        FauxMQ.Debug.log(
          :info,
          "[FauxMQ.Server] accept ok, conn_id=#{connection_id}, spawning Connection"
        )

        {:ok, pid} =
          FauxMQ.Connection.start_link(
            socket: socket,
            server: self(),
            mock_server: state.mock_server,
            connection_id: connection_id,
            protocol_module: Protocol
          )

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :socket_ready)

        FauxMQ.Debug.log(
          :info,
          "[FauxMQ.Server] conn_id=#{connection_id} controlling_process done, sent socket_ready"
        )

        new_state = %{
          state
          | connections: Map.put(state.connections, connection_id, pid),
            next_connection_id: connection_id + 1
        }

        send(self(), :accept)
        {:noreply, new_state}

      {:error, :closed} ->
        FauxMQ.Debug.log(:debug, "[FauxMQ.Server] accept: listener closed")
        {:noreply, state}

      {:error, :timeout} ->
        # Normal when no client is waiting; we use timeout 0 (non-blocking)
        FauxMQ.Debug.log(:debug, "[FauxMQ.Server] accept: timeout (no client waiting)")
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        FauxMQ.Debug.log(:error, "[FauxMQ.Server] accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.listener do
      :gen_tcp.close(state.listener)
    end

    :ok
  end

  # Routing behaviour:
  #   * if there is an explicit binding for {exchange, routing_key}, use its queue_name
  #   * otherwise fall back to treating routing_key as the queue name
  defp queue_for_publish(%__MODULE__{bindings: bindings}, exchange, routing_key) do
    Map.get(bindings, {exchange, routing_key}, routing_key)
  end

  defp append_to_queue(queues, queue_name, message) do
    list = Map.get(queues, queue_name, [])
    Map.put(queues, queue_name, list ++ [message])
  end

  defp maybe_deliver_to_consumers(
         %__MODULE__{consumers: consumers, connections: connections} = state,
         queue_name,
         message
       ) do
    case Map.get(consumers, queue_name) do
      nil ->
        state

      [] ->
        state

      consumer_list when is_list(consumer_list) ->
        Enum.each(consumer_list, fn consumer ->
          with %{connection_id: conn_id, channel_id: channel_id, consumer_tag: consumer_tag} <-
                 consumer,
               pid when is_pid(pid) <- Map.get(connections, conn_id) do
            delivery = %{
              channel_id: channel_id,
              consumer_tag: consumer_tag,
              exchange: message.exchange,
              routing_key: message.routing_key,
              payload: message.body,
              delivery_tag: consumer.delivery_tag,
              redelivered: false
            }

            send(pid, {:push_delivery, delivery})
          else
            _ -> :ok
          end
        end)

        state
    end
  end
end

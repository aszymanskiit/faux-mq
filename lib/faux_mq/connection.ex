defmodule FauxMQ.Connection do
  @moduledoc """
  Represents a single TCP connection that speaks AMQP 0-9-1.

  This process owns the socket and is responsible for:

    * parsing the AMQP protocol header
    * performing connection negotiation (start / start-ok / tune / tune-ok / open / open-ok)
    * multiplexing channels and dispatching frames
    * integrating with `FauxMQ.MockServer` and the stateful broker
  """

  use GenServer

  alias FauxMQ.MockServer
  alias FauxMQ.Protocol.Frame

  defstruct [
    :socket,
    :server,
    :mock_server,
    :protocol_module,
    :connection_id,
    :buffer,
    :phase,
    :channels,
    :heartbeat_interval,
    :pending_content
  ]

  @type pending_content_entry :: %{
          exchange: binary(),
          routing_key: binary(),
          body_size: non_neg_integer() | nil,
          body_acc: binary()
        }

  @type t :: %__MODULE__{
          socket: port(),
          server: pid(),
          mock_server: pid(),
          protocol_module: module(),
          connection_id: non_neg_integer(),
          buffer: binary(),
          phase: :handshake | :running,
          channels: map(),
          heartbeat_interval: non_neg_integer(),
          pending_content: %{non_neg_integer() => pending_content_entry()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)
    server = Keyword.fetch!(opts, :server)
    mock_server = Keyword.fetch!(opts, :mock_server)
    protocol_module = Keyword.fetch!(opts, :protocol_module)
    connection_id = Keyword.fetch!(opts, :connection_id)

    # Do not set active: :once here; Server must call controlling_process first, then send
    # :socket_ready so we don't lose the first packet (AMQP header).

    state = %__MODULE__{
      socket: socket,
      server: server,
      mock_server: mock_server,
      protocol_module: protocol_module,
      connection_id: connection_id,
      buffer: <<>>,
      phase: :handshake,
      channels: %{},
      heartbeat_interval: Application.get_env(:faux_mq, :heartbeat_interval, 0),
      pending_content: %{}
    }

    FauxMQ.Debug.log(:info, "[FauxMQ.Connection] conn_id=#{connection_id} init, phase=handshake")
    {:ok, state}
  end

  @impl true
  def handle_info(:socket_ready, state) do
    FauxMQ.Debug.log(
      :info,
      "[FauxMQ.Connection] conn_id=#{state.connection_id} socket_ready, setting active: :once"
    )

    case set_active_once(state.socket) do
      :ok -> {:noreply, state}
      {:error, :einval} -> {:stop, :normal, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:tcp, _socket, data}, state) do
    new_buffer = state.buffer <> data

    FauxMQ.Debug.log(
      :info,
      "[FauxMQ.Connection] conn_id=#{state.connection_id} tcp data #{byte_size(data)} bytes, buffer_total=#{byte_size(new_buffer)}, phase=#{state.phase}" <>
        if(state.phase == :handshake and byte_size(new_buffer) > 0,
          do:
            " first_bytes=#{inspect(binary_part(new_buffer, 0, min(12, byte_size(new_buffer))))}",
          else: ""
        )
    )

    case state.phase do
      :handshake ->
        handle_handshake_bytes(%{state | buffer: new_buffer})

      :running ->
        handle_running_bytes(%{state | buffer: new_buffer})
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    FauxMQ.Debug.log(:info, "[FauxMQ.Connection] conn_id=#{state.connection_id} tcp_closed")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    FauxMQ.Debug.log(
      :warning,
      "[FauxMQ.Connection] conn_id=#{state.connection_id} tcp_error: #{inspect(reason)}"
    )

    {:stop, reason, state}
  end

  def handle_info({:push_frame, frame_spec}, state) do
    frame = %Frame{
      type: frame_spec.type,
      channel: frame_spec.channel,
      payload: frame_spec.payload
    }

    send_frame(state, frame)
    {:noreply, state}
  end

  def handle_info({:push_delivery, delivery}, state) do
    %{
      channel_id: channel,
      consumer_tag: consumer_tag,
      exchange: exchange,
      routing_key: routing_key,
      payload: payload,
      delivery_tag: delivery_tag,
      redelivered: redelivered
    } = delivery

    frames =
      state.protocol_module.build_basic_deliver_frames(
        channel,
        consumer_tag,
        delivery_tag,
        redelivered,
        exchange,
        routing_key,
        payload
      )

    Enum.each(frames, &send_frame(state, &1))
    {:noreply, state}
  end

  def handle_info(msg, state) do
    FauxMQ.Debug.log(:debug, "Unexpected message in FauxMQ.Connection: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_handshake_bytes(state) do
    case state.buffer do
      # Accept AMQP 0-9-0 and 0-9-1 (revision 0 or 1); strict 0-9-1 only caused connection close for some clients
      <<"AMQP", 0, 0, 9, rev, rest::binary>> ->
        FauxMQ.Debug.log(
          :info,
          "[FauxMQ.Connection] conn_id=#{state.connection_id} handshake: protocol header ok (0-9-#{rev}), rest=#{byte_size(rest)} bytes, sending connection.start"
        )

        case state.protocol_module.send_connection_start(state.socket) do
          :ok ->
            state1 = %{state | buffer: rest, phase: :running}

            FauxMQ.Debug.log(
              :info,
              "[FauxMQ.Connection] conn_id=#{state.connection_id} connection.start sent, phase=running"
            )

            handshake_continue(state1, rest)

          {:error, reason} ->
            FauxMQ.Debug.log(
              :warning,
              "[FauxMQ.Connection] conn_id=#{state.connection_id} send connection.start failed: #{inspect(reason)}, closing"
            )

            :gen_tcp.close(state.socket)
            {:stop, :send_error, state}
        end

      _ when byte_size(state.buffer) < 8 ->
        FauxMQ.Debug.log(
          :debug,
          "[FauxMQ.Connection] conn_id=#{state.connection_id} handshake: need more (buffer=#{byte_size(state.buffer)} < 8)"
        )

        case set_active_once(state.socket) do
          :ok -> {:noreply, state}
          {:error, :einval} -> {:stop, :normal, state}
          {:error, reason} -> {:stop, reason, state}
        end

      other ->
        first = binary_part(other, 0, min(8, byte_size(other)))

        FauxMQ.Debug.log(
          :warning,
          "[FauxMQ.Connection] conn_id=#{state.connection_id} handshake: invalid header first_bytes=#{inspect(first)}, closing"
        )

        :gen_tcp.close(state.socket)
        {:stop, :protocol_header, state}
    end
  end

  defp handshake_continue(state1, rest) do
    # Process any data already in buffer (e.g. connection.start_ok in same packet)
    if rest != <<>> do
      FauxMQ.Debug.log(
        :info,
        "[FauxMQ.Connection] conn_id=#{state1.connection_id} handshake_continue: decoding #{byte_size(rest)} bytes after header"
      )

      case state1.protocol_module.decode_frames(rest) do
        {:ok, frames, rest2} ->
          FauxMQ.Debug.log(
            :info,
            "[FauxMQ.Connection] conn_id=#{state1.connection_id} decode_frames ok: #{length(frames)} frame(s), rest=#{byte_size(rest2)} bytes"
          )

          new_state =
            Enum.reduce(frames, state1, fn frame, acc ->
              handle_frame(acc, frame)
            end)

          case set_active_once(new_state.socket) do
            :ok -> {:noreply, %{new_state | buffer: rest2}}
            {:error, :einval} -> {:stop, :normal, state1}
            {:error, reason} -> {:stop, reason, state1}
          end

        {:incomplete, needed} ->
          FauxMQ.Debug.log(
            :info,
            "[FauxMQ.Connection] conn_id=#{state1.connection_id} decode_frames incomplete, need #{needed} more bytes"
          )

          case set_active_once(state1.socket) do
            :ok -> {:noreply, state1}
            {:error, :einval} -> {:stop, :normal, state1}
            {:error, reason} -> {:stop, reason, state1}
          end
      end
    else
      FauxMQ.Debug.log(
        :info,
        "[FauxMQ.Connection] conn_id=#{state1.connection_id} handshake_continue: no extra data, waiting for start_ok"
      )

      case set_active_once(state1.socket) do
        :ok -> {:noreply, state1}
        {:error, :einval} -> {:stop, :normal, state1}
        {:error, reason} -> {:stop, reason, state1}
      end
    end
  end

  defp handle_running_bytes(state) do
    if Process.alive?(state.server) do
      handle_running_bytes_decode(state)
    else
      FauxMQ.Debug.log(
        :warning,
        "[FauxMQ.Connection] conn_id=#{state.connection_id} server process not alive, stopping"
      )

      {:stop, :server_down, state}
    end
  end

  defp handle_running_bytes_decode(state) do
    case state.protocol_module.decode_frames(state.buffer) do
      {:ok, frames, rest} ->
        try do
          new_state =
            Enum.reduce(frames, state, fn frame, acc ->
              handle_frame(acc, frame)
            end)

          case set_active_once(new_state.socket) do
            :ok -> {:noreply, %{new_state | buffer: rest}}
            {:error, :einval} -> {:stop, :normal, state}
            {:error, reason} -> {:stop, reason, state}
          end
        catch
          :exit, {:noproc, _} = _reason ->
            FauxMQ.Debug.log(
              :warning,
              "[FauxMQ.Connection] conn_id=#{state.connection_id} server call failed (noproc), stopping"
            )

            {:stop, :server_down, state}

          :exit, reason ->
            FauxMQ.Debug.log(
              :warning,
              "[FauxMQ.Connection] conn_id=#{state.connection_id} exit during frame handling: #{inspect(reason)}"
            )

            {:stop, reason, state}
        end

      {:incomplete, _needed} ->
        case set_active_once(state.socket) do
          :ok -> {:noreply, state}
          {:error, :einval} -> {:stop, :normal, state}
          {:error, reason} -> {:stop, reason, state}
        end
    end
  end

  defp set_active_once(socket) do
    :inet.setopts(socket, active: :once)
  end

  # Avoids crashing when Server is dead (e.g. noproc); returns default after timeout or exit.
  defp safe_server_call(server, message, default, timeout \\ 5_000) do
    try do
      GenServer.call(server, message, timeout)
    catch
      :exit, _ -> default
    end
  end

  defp handle_frame(state, %Frame{type: :heartbeat}) do
    send_frame(state, %Frame{type: :heartbeat, channel: 0, payload: <<>>})
    state
  end

  defp handle_frame(state, %Frame{type: :header, channel: channel, payload: payload}) do
    case Map.get(state.pending_content, channel) do
      nil ->
        state

      entry when is_map(entry) and entry.body_size == nil ->
        case state.protocol_module.parse_content_header_body_size(payload) do
          {:ok, body_size} ->
            updated = %{entry | body_size: body_size}
            put_in(state.pending_content[channel], updated)

          :error ->
            state
        end
    end
  end

  defp handle_frame(state, %Frame{type: :body, channel: channel, payload: payload}) do
    case Map.get(state.pending_content, channel) do
      nil ->
        state

      entry when is_map(entry) and is_integer(entry.body_size) ->
        acc = entry.body_acc <> payload

        if byte_size(acc) >= entry.body_size do
          body = binary_part(acc, 0, entry.body_size)

          _ =
            safe_server_call(
              state.server,
              {:basic_publish, entry.exchange, entry.routing_key, body},
              :ok
            )

          pending_content = Map.delete(state.pending_content, channel)
          %{state | pending_content: pending_content}
        else
          updated = %{entry | body_acc: acc}
          put_in(state.pending_content[channel], updated)
        end
    end
  end

  defp handle_frame(state, %Frame{type: :method, channel: channel, payload: payload} = frame) do
    method_ctx =
      try do
        {class_id, method_id, args} = state.protocol_module.parse_method_payload(payload)
        method_name = state.protocol_module.method_name(class_id, method_id)

        FauxMQ.Debug.log(
          :info,
          "[FauxMQ.Connection] conn_id=#{state.connection_id} frame: #{method_name} channel=#{channel}"
        )

        call_ctx = %{
          connection_id: state.connection_id,
          channel_id: channel,
          class_id: class_id,
          method_id: method_id,
          method_name: method_name,
          args: args
        }

        MockServer.record_call(state.mock_server, call_ctx)

        case MockServer.match_rule(state.mock_server, call_ctx) do
          {:action, action} ->
            execute_action(state, frame, call_ctx, action)

          :nomatch ->
            execute_default(state, frame, call_ctx)
        end
      rescue
        e ->
          FauxMQ.Debug.log(
            :error,
            "[FauxMQ.Connection] conn_id=#{state.connection_id} handle_frame CRASH: #{inspect(e)}, payload_size=#{byte_size(payload)}"
          )

          reraise e, __STACKTRACE__
      end

    method_ctx
  end

  defp handle_frame(state, other) do
    FauxMQ.Debug.log(
      :debug,
      "[FauxMQ.Connection] conn_id=#{state.connection_id} frame ignored: #{inspect(other)}"
    )

    state
  end

  @impl true
  def terminate(reason, state) do
    FauxMQ.Debug.log(
      :info,
      "[FauxMQ.Connection] conn_id=#{state.connection_id} terminate reason=#{inspect(reason)}"
    )

    :ok
  end

  defp execute_action(state, _frame, call_ctx, {:delay, ms, action}) do
    Process.send_after(self(), {:delayed_action, call_ctx, action}, ms)
    state
  end

  defp execute_action(state, frame, call_ctx, {:sequence, actions}) do
    Enum.reduce(actions, state, fn action, acc ->
      execute_action(acc, frame, call_ctx, action)
    end)
  end

  defp execute_action(state, _frame, _call_ctx, :no_reply) do
    state
  end

  defp execute_action(state, _frame, _call_ctx, :close_connection) do
    :gen_tcp.close(state.socket)
    state
  end

  defp execute_action(state, %Frame{channel: channel}, _call_ctx, :close_channel) do
    close = state.protocol_module.build_channel_close(channel, 200, "Closed by mock", 0, 0)
    send_frame(state, close)
    state
  end

  defp execute_action(state, frame, _call_ctx, :protocol_error) do
    error_frame =
      state.protocol_module.build_connection_close(
        0,
        540,
        "Mocked protocol error",
        frame.channel,
        0
      )

    send_frame(state, error_frame)
    :gen_tcp.close(state.socket)
    state
  end

  defp execute_action(state, _frame, _call_ctx, {:reply, {:frames, frames}}) do
    Enum.each(frames, &send_frame(state, &1))
    state
  end

  defp execute_action(state, _frame, _call_ctx, {:reply, {:method, class_id, method_id, args}}) do
    frame =
      state.protocol_module.build_method_frame(
        0,
        class_id,
        method_id,
        args
      )

    send_frame(state, frame)
    state
  end

  defp execute_default(state, _frame, call_ctx) do
    # minimal handshake and channel lifecycle for compatibility
    case call_ctx do
      %{class_id: 10, method_id: 11} ->
        # connection.start-ok -> send connection.tune (channel_max=0 no limit, frame_max=128K, heartbeat=0)
        tune = state.protocol_module.build_connection_tune(0, 0, 131_072, 0)
        send_frame(state, tune)
        state

      %{class_id: 10, method_id: 31} ->
        # connection.tune-ok
        state

      %{class_id: 10, method_id: 40} ->
        # connection.open -> open-ok
        open_ok = state.protocol_module.build_connection_open_ok("/")
        send_frame(state, open_ok)
        state

      %{class_id: 20, method_id: 10, channel_id: channel} ->
        # channel.open -> open-ok
        open_ok = state.protocol_module.build_channel_open_ok(channel)
        send_frame(state, open_ok)
        state

      %{class_id: 20, method_id: 40, channel_id: channel} ->
        close_ok = state.protocol_module.build_channel_close_ok(channel)
        send_frame(state, close_ok)
        state

      %{class_id: 50, method_id: 10, channel_id: channel, args: args} ->
        case state.protocol_module.parse_queue_declare_args(args) do
          {:ok, queue_name} ->
            _ = safe_server_call(state.server, {:queue_ensure, queue_name}, :ok)
            declare_ok = state.protocol_module.build_queue_declare_ok(channel, queue_name)
            send_frame(state, declare_ok)
            state

          :error ->
            state
        end

      %{class_id: 50, method_id: 30, channel_id: channel, args: args} ->
        case state.protocol_module.parse_queue_declare_args(args) do
          {:ok, queue_name} ->
            count = safe_server_call(state.server, {:queue_purge, queue_name}, 0)
            purge_ok = state.protocol_module.build_queue_purge_ok(channel, count)
            send_frame(state, purge_ok)
            state

          :error ->
            state
        end

      %{class_id: 60, method_id: 40, channel_id: channel, args: args} ->
        case state.protocol_module.parse_basic_publish_args(args) do
          {:ok, exchange, routing_key} ->
            entry = %{
              exchange: exchange,
              routing_key: routing_key,
              body_size: nil,
              body_acc: <<>>
            }

            pending_content = Map.put(state.pending_content, channel, entry)
            %{state | pending_content: pending_content}

          :error ->
            state
        end

      %{class_id: 60, method_id: 70, channel_id: channel, args: args} ->
        case state.protocol_module.parse_basic_get_args(args) do
          {:ok, queue_name, _no_ack} ->
            case safe_server_call(state.server, {:basic_get, queue_name}, :empty) do
              {:ok, payload, message_count} ->
                frames =
                  state.protocol_module.build_basic_get_ok_frames(
                    channel,
                    1,
                    false,
                    "",
                    queue_name,
                    message_count,
                    payload
                  )

                Enum.each(frames, &send_frame(state, &1))
                state

              :empty ->
                get_empty = state.protocol_module.build_basic_get_empty(channel)
                send_frame(state, get_empty)
                state
            end

          :error ->
            state
        end

      %{class_id: 10, method_id: 50} ->
        # connection.close -> close-ok and close socket
        close_ok = state.protocol_module.build_connection_close_ok()
        send_frame(state, close_ok)
        :gen_tcp.close(state.socket)
        state

      _ ->
        state
    end
  end

  defp send_frame(state, frame) do
    bin = state.protocol_module.encode_frame(frame)

    case :gen_tcp.send(state.socket, bin) do
      :ok ->
        :ok

      {:error, reason} ->
        FauxMQ.Debug.log(
          :warning,
          "[FauxMQ.Connection] conn_id=#{state.connection_id} send_frame failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end

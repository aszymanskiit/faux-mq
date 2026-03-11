defmodule FauxMQ.Protocol do
  @moduledoc """
  Core AMQP 0-9-1 protocol implementation for FauxMQ.

  This module is responsible for:

    * encoding and decoding frames
    * building common method frames used by the handshake and channel lifecycle
    * mapping class/method IDs to symbolic names
  """

  alias FauxMQ.Protocol.Frame

  @frame_end 206

  @spec encode_frame(Frame.t()) :: binary()
  def encode_frame(%Frame{type: type, channel: channel, payload: payload}) do
    type_id =
      case type do
        :method -> 1
        :header -> 2
        :body -> 3
        :heartbeat -> 8
      end

    size = byte_size(payload)
    <<type_id, channel::16, size::32, payload::binary, @frame_end>>
  end

  @spec decode_frames(binary()) :: {:ok, [Frame.t()], binary()} | {:incomplete, non_neg_integer()}
  def decode_frames(binary), do: decode_frames(binary, [])

  defp decode_frames(<<>>, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp decode_frames(<<type_id, channel::16, size::32, rest::binary>>, acc) do
    total_needed = size + 1

    if byte_size(rest) < total_needed do
      FauxMQ.Debug.log(
        :debug,
        "[FauxMQ.Protocol] decode_frames incomplete: type_id=#{type_id} channel=#{channel} size=#{size} need #{total_needed - byte_size(rest)} more"
      )

      {:incomplete, total_needed - byte_size(rest)}
    else
      <<payload::binary-size(size), @frame_end, remaining::binary>> = rest

      type =
        case type_id do
          1 -> :method
          2 -> :header
          3 -> :body
          8 -> :heartbeat
        end

      frame = %Frame{type: type, channel: channel, payload: payload}
      decode_frames(remaining, [frame | acc])
    end
  end

  defp decode_frames(_incomplete, _acc) do
    {:incomplete, 1}
  end

  @doc """
  Extracts class and method IDs plus arguments from a method frame payload.
  """
  @spec parse_method_payload(binary()) :: {non_neg_integer(), non_neg_integer(), binary()}
  def parse_method_payload(<<class_id::16, method_id::16, args::binary>>) do
    {class_id, method_id, args}
  end

  @doc """
  Parses queue name from queue.declare method args (reserved short, then shortstr queue-name).
  """
  @spec parse_queue_declare_args(binary()) :: {:ok, binary()} | :error
  def parse_queue_declare_args(<<_reserved::16, len::8, queue_name::binary-size(len), _::binary>>)
      when len <= 255 do
    {:ok, queue_name}
  end

  def parse_queue_declare_args(_), do: :error

  @doc """
  Parses queue.delete method args (reserved short, then shortstr queue-name, flags).
  """
  @spec parse_queue_delete_args(binary()) :: {:ok, binary()} | :error
  def parse_queue_delete_args(
        <<_reserved::16, len::8, queue_name::binary-size(len), _flags::8, _rest::binary>>
      )
      when len <= 255 do
    {:ok, queue_name}
  end

  def parse_queue_delete_args(_), do: :error

  @doc """
  Parses exchange.declare method args to extract the exchange name.
  We only care about the exchange shortstr and ignore flags/arguments.
  """
  @spec parse_exchange_declare_args(binary()) :: {:ok, binary()} | :error
  def parse_exchange_declare_args(
        <<_reserved::16, elen::8, exchange::binary-size(elen), _rest::binary>>
      )
      when elen <= 255 do
    {:ok, exchange}
  end

  def parse_exchange_declare_args(_), do: :error

  @doc """
  Parses queue.bind method args:
  reserved-1 (short), queue-name (shortstr), exchange (shortstr), routing-key (shortstr),
  then flags and arguments (ignored).
  """
  @spec parse_queue_bind_args(binary()) ::
          {:ok, queue_name :: binary(), exchange :: binary(), routing_key :: binary()} | :error
  def parse_queue_bind_args(
        <<_reserved::16, qlen::8, queue::binary-size(qlen), elen::8,
          exchange::binary-size(elen), rlen::8, routing_key::binary-size(rlen), _rest::binary>>
      )
      when qlen <= 255 and elen <= 255 and rlen <= 255 do
    {:ok, queue, exchange, routing_key}
  end

  def parse_queue_bind_args(_), do: :error

  @doc """
  Parses basic.publish method args: reserved (short), exchange (shortstr), routing_key (shortstr), mandatory (bit), immediate (bit).
  """
  @spec parse_basic_publish_args(binary()) :: {:ok, binary(), binary()} | :error
  def parse_basic_publish_args(
        <<_reserved::16, ex_len::8, exchange::binary-size(ex_len), rk_len::8,
          routing_key::binary-size(rk_len), _::binary>>
      )
      when ex_len <= 255 and rk_len <= 255 do
    {:ok, exchange, routing_key}
  end

  def parse_basic_publish_args(_), do: :error

  @doc """
  Parses basic.get method args: reserved (short), queue-name (shortstr), no-ack (bit).
  """
  @spec parse_basic_get_args(binary()) :: {:ok, binary(), boolean()} | :error
  def parse_basic_get_args(
        <<_reserved::16, len::8, queue_name::binary-size(len), flags::8, _::binary>>
      )
      when len <= 255 do
    no_ack = rem(flags, 2) == 1
    {:ok, queue_name, no_ack}
  end

  def parse_basic_get_args(_), do: :error

  @doc """
  Parses basic.consume method args:
  reserved (short), queue-name (shortstr), consumer-tag (shortstr), flags (bits), arguments (table).

  For FauxMQ we only care about the queue name and consumer tag.
  """
  @spec parse_basic_consume_args(binary()) :: {:ok, binary(), binary()} | :error
  def parse_basic_consume_args(
        <<_reserved::16, qlen::8, queue::binary-size(qlen), tlen::8,
          consumer_tag::binary-size(tlen), _flags::8, _rest::binary>>
      )
      when qlen <= 255 and tlen <= 255 do
    {:ok, queue, consumer_tag}
  end

  def parse_basic_consume_args(_), do: :error

  @doc """
  Parses basic.cancel method args:
  reserved (short), consumer-tag (shortstr), nowait (bit).
  """
  @spec parse_basic_cancel_args(binary()) :: {:ok, binary()} | :error
  def parse_basic_cancel_args(
        <<_reserved::16, tlen::8, consumer_tag::binary-size(tlen), _flags::8, _rest::binary>>
      )
      when tlen <= 255 do
    {:ok, consumer_tag}
  end

  def parse_basic_cancel_args(_), do: :error

  @doc """
  Parses content header (class 60 basic) to obtain body size.
  Format: class-id (16), weight (16), body-size (64), property-flags (16).
  """
  @spec parse_content_header_body_size(binary()) :: {:ok, non_neg_integer()} | :error
  def parse_content_header_body_size(<<_class_id::16, _weight::16, body_size::64, _::binary>>) do
    {:ok, body_size}
  end

  def parse_content_header_body_size(_), do: :error

  @doc """
  Builds a generic method frame on channel 0.
  """
  @spec build_method_frame(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary()) ::
          Frame.t()
  def build_method_frame(channel, class_id, method_id, args) do
    payload = <<class_id::16, method_id::16, args::binary>>
    %Frame{type: :method, channel: channel, payload: payload}
  end

  @doc """
  Sends the initial `connection.start` method on channel 0.
  """
  @spec send_connection_start(port()) :: :ok | {:error, term()}
  def send_connection_start(socket) do
    server_properties = encode_table(%{"product" => "FauxMQ", "version" => "0.1.0"})
    mechanisms = encode_longstr("PLAIN")
    locales = encode_longstr("en_US")

    args =
      <<0::8, 9::8, server_properties::binary, mechanisms::binary, locales::binary>>

    frame = build_method_frame(0, 10, 10, args)
    :gen_tcp.send(socket, encode_frame(frame))
  end

  @spec build_connection_tune(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          Frame.t()
  def build_connection_tune(channel, channel_max, frame_max, heartbeat \\ 0) do
    args = <<channel_max::16, frame_max::32, heartbeat::16>>
    build_method_frame(channel, 10, 30, args)
  end

  # connection.open-ok has a single shortstr (reserved-1) per AMQP 0-9-1; do not send two fields
  @spec build_connection_open_ok(binary()) :: Frame.t()
  def build_connection_open_ok(_known_hosts) do
    args = encode_shortstr("")
    build_method_frame(0, 10, 41, args)
  end

  @spec build_connection_close(non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) ::
          Frame.t()
  def build_connection_close(reply_code, reply_text, class_id, method_id) do
    args =
      <<reply_code::16, encode_shortstr(reply_text)::binary, class_id::16, method_id::16>>

    build_method_frame(0, 10, 50, args)
  end

  @spec build_connection_close_ok() :: Frame.t()
  def build_connection_close_ok do
    build_method_frame(0, 10, 51, <<>>)
  end

  @spec build_channel_open_ok(non_neg_integer()) :: Frame.t()
  def build_channel_open_ok(channel) do
    args = encode_longstr("")
    build_method_frame(channel, 20, 11, args)
  end

  @spec build_queue_declare_ok(non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()) ::
          Frame.t()
  def build_queue_declare_ok(channel, queue_name, message_count, consumer_count) do
    # declare-ok: queue-name (shortstr), message-count (long), consumer-count (long)
    args = encode_shortstr(queue_name) <> <<message_count::32, consumer_count::32>>
    build_method_frame(channel, 50, 11, args)
  end

  @spec build_queue_purge_ok(non_neg_integer(), non_neg_integer()) :: Frame.t()
  def build_queue_purge_ok(channel, message_count \\ 0) do
    args = <<message_count::32>>
    build_method_frame(channel, 50, 31, args)
  end

  @doc """
  Builds queue.delete-ok method frame.
  """
  @spec build_queue_delete_ok(non_neg_integer(), non_neg_integer()) :: Frame.t()
  def build_queue_delete_ok(channel, message_count \\ 0) do
    args = <<message_count::32>>
    build_method_frame(channel, 50, 41, args)
  end

  @doc """
  Builds basic.qos-ok method frame.
  """
  @spec build_basic_qos_ok(non_neg_integer()) :: Frame.t()
  def build_basic_qos_ok(channel) do
    # basic.qos-ok has no payload fields
    build_method_frame(channel, 60, 11, <<>>)
  end

  @spec build_queue_bind_ok(non_neg_integer()) :: Frame.t()
  def build_queue_bind_ok(channel) do
    # queue.bind-ok has no payload fields
    build_method_frame(channel, 50, 21, <<>>)
  end

  @spec build_channel_close(
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          Frame.t()
  def build_channel_close(channel, reply_code, reply_text, class_id, method_id) do
    args =
      <<reply_code::16, encode_shortstr(reply_text)::binary, class_id::16, method_id::16>>

    build_method_frame(channel, 20, 40, args)
  end

  @spec build_channel_close_ok(non_neg_integer()) :: Frame.t()
  def build_channel_close_ok(channel) do
    build_method_frame(channel, 20, 41, <<>>)
  end

  @doc """
  Builds basic.get-ok method frame plus content (header + body) frames.
  delivery_tag, redelivered, exchange, routing_key, message_count; then payload for content.
  """
  @spec build_basic_get_ok_frames(
          channel :: non_neg_integer(),
          delivery_tag :: non_neg_integer(),
          redelivered :: boolean(),
          exchange :: binary(),
          routing_key :: binary(),
          message_count :: non_neg_integer(),
          payload :: binary(),
          header_payload :: binary() | nil
        ) :: [Frame.t()]
  def build_basic_get_ok_frames(
        channel,
        delivery_tag,
        redelivered,
        exchange,
        routing_key,
        message_count,
        payload,
        header_payload \\ nil
      ) do
    redelivered_octet = if redelivered, do: 1, else: 0

    method_args =
      <<delivery_tag::64, redelivered_octet::8>> <>
        encode_shortstr(exchange) <>
        encode_shortstr(routing_key) <>
        <<message_count::32>>

    method_frame = build_method_frame(channel, 60, 71, method_args)

    {header_frame, body_frame} =
      case header_payload do
        nil ->
          # Fallback: minimal header with no properties.
          [h, b] = build_content_frames(channel, payload)
          {h, b}

        hp when is_binary(hp) ->
          header_frame = %Frame{type: :header, channel: channel, payload: hp}
          body_frame = %Frame{type: :body, channel: channel, payload: payload}
          {header_frame, body_frame}
      end

    [method_frame, header_frame, body_frame]
  end

  @doc """
  Builds basic.get-empty method frame (single shortstr reserved-1).
  """
  @spec build_basic_get_empty(non_neg_integer()) :: Frame.t()
  def build_basic_get_empty(channel) do
    args = encode_shortstr("")
    build_method_frame(channel, 60, 72, args)
  end

  @doc """
  Builds basic.consume-ok frame with a consumer tag.
  """
  @spec build_basic_consume_ok(non_neg_integer(), binary()) :: Frame.t()
  def build_basic_consume_ok(channel, consumer_tag) do
    args = encode_shortstr(consumer_tag)
    build_method_frame(channel, 60, 21, args)
  end

  @doc """
  Builds basic.cancel-ok frame with a consumer tag.
  """
  @spec build_basic_cancel_ok(non_neg_integer(), binary()) :: Frame.t()
  def build_basic_cancel_ok(channel, consumer_tag) do
    args = encode_shortstr(consumer_tag)
    build_method_frame(channel, 60, 31, args)
  end

  @doc """
  Builds exchange.declare-ok frame.
  """
  @spec build_exchange_declare_ok(non_neg_integer()) :: Frame.t()
  def build_exchange_declare_ok(channel) do
    # exchange.declare-ok has no payload fields
    build_method_frame(channel, 40, 11, <<>>)
  end

  @doc """
  Builds exchange.delete-ok frame.
  """
  @spec build_exchange_delete_ok(non_neg_integer()) :: Frame.t()
  def build_exchange_delete_ok(channel) do
    # exchange.delete-ok has no payload fields
    build_method_frame(channel, 40, 21, <<>>)
  end

  @doc """
  Builds content header and body frames for basic class (class-id 60).
  """
  @spec build_content_frames(channel :: non_neg_integer(), payload :: binary()) :: [Frame.t()]
  def build_content_frames(channel, payload) do
    body_size = byte_size(payload)
    header_payload = <<60::16, 0::16, body_size::64, 0::16>>
    header_frame = %Frame{type: :header, channel: channel, payload: header_payload}
    body_frame = %Frame{type: :body, channel: channel, payload: payload}
    [header_frame, body_frame]
  end

  @doc """
  Builds frames for `basic.deliver` with content header and body.
  """
  @spec build_basic_deliver_frames(
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          boolean(),
          binary(),
          binary(),
          binary(),
          binary() | nil
        ) :: [Frame.t()]
  def build_basic_deliver_frames(
        channel,
        consumer_tag,
        delivery_tag,
        redelivered,
        exchange,
        routing_key,
        payload,
        header_payload \\ nil
      ) do
    redelivered_flag = if redelivered, do: 1, else: 0

    method_args =
      encode_shortstr(consumer_tag) <>
        <<delivery_tag::64, redelivered_flag::8>> <>
        encode_shortstr(exchange) <>
        encode_shortstr(routing_key)

    method_frame = build_method_frame(channel, 60, 60, method_args)

    {header_frame, body_frame} =
      case header_payload do
        nil ->
          # Minimal header with no properties when header payload is not provided.
          [h, b] = build_content_frames(channel, payload)
          {h, b}

        hp when is_binary(hp) ->
          header_frame = %Frame{type: :header, channel: channel, payload: hp}
          body_frame = %Frame{type: :body, channel: channel, payload: payload}
          {header_frame, body_frame}
      end

    [method_frame, header_frame, body_frame]
  end

  @doc """
  Maps class and method IDs to a symbolic atom where known.
  """
  @spec method_name(non_neg_integer(), non_neg_integer()) :: atom() | nil
  def method_name(10, 10), do: :connection_start
  def method_name(10, 11), do: :connection_start_ok
  def method_name(10, 20), do: :connection_secure
  def method_name(10, 21), do: :connection_secure_ok
  def method_name(10, 30), do: :connection_tune
  def method_name(10, 31), do: :connection_tune_ok
  def method_name(10, 40), do: :connection_open
  def method_name(10, 41), do: :connection_open_ok
  def method_name(10, 50), do: :connection_close
  def method_name(10, 51), do: :connection_close_ok
  def method_name(20, 10), do: :channel_open
  def method_name(20, 11), do: :channel_open_ok
  def method_name(20, 40), do: :channel_close
  def method_name(20, 41), do: :channel_close_ok
  def method_name(40, 10), do: :exchange_declare
  def method_name(40, 11), do: :exchange_declare_ok
  def method_name(40, 20), do: :exchange_delete
  def method_name(40, 21), do: :exchange_delete_ok
  def method_name(50, 10), do: :queue_declare
  def method_name(50, 11), do: :queue_declare_ok
  def method_name(50, 30), do: :queue_purge
  def method_name(50, 31), do: :queue_purge_ok
  def method_name(50, 40), do: :queue_delete
  def method_name(50, 41), do: :queue_delete_ok
  def method_name(60, 10), do: :basic_qos
  def method_name(60, 30), do: :basic_cancel
  def method_name(60, 31), do: :basic_cancel_ok
  def method_name(60, 40), do: :basic_publish
  def method_name(60, 20), do: :basic_consume
  def method_name(60, 21), do: :basic_consume_ok
  def method_name(60, 60), do: :basic_deliver
  def method_name(60, 70), do: :basic_get
  def method_name(60, 71), do: :basic_get_ok
  def method_name(60, 72), do: :basic_get_empty
  def method_name(_c, _m), do: nil

  ## Encoding helpers

  @spec encode_shortstr(binary()) :: binary()
  def encode_shortstr(str) when byte_size(str) <= 255 do
    <<byte_size(str)::8, str::binary>>
  end

  @spec encode_longstr(binary()) :: binary()
  def encode_longstr(str) do
    <<byte_size(str)::32, str::binary>>
  end

  @spec encode_table(map()) :: binary()
  def encode_table(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} ->
        key = to_string(k)
        value = encode_field_value(v)
        encode_shortstr(key) <> value
      end)
      |> IO.iodata_to_binary()

    <<byte_size(inner)::32, inner::binary>>
  end

  defp encode_field_value(v) when is_binary(v), do: <<"S", encode_longstr(v)::binary>>
  defp encode_field_value(v) when is_integer(v), do: <<"I", v::32>>
  defp encode_field_value(true), do: <<"t", 1>>
  defp encode_field_value(false), do: <<"t", 0>>
  defp encode_field_value(nil), do: <<"V">>

  defp encode_field_value(map) when is_map(map) do
    <<"F", encode_table(map)::binary>>
  end
end

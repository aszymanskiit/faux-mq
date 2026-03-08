defmodule FauxMQ.MockingTest do
  use ExUnit.Case, async: false

  alias FauxMQ.Protocol

  test "allows stubbing a connection.close on basic.publish" do
    {:ok, server} = FauxMQ.start_link(port: 0)
    port = FauxMQ.port(server)

    FauxMQ.stub(server, %{class_id: 60, method_id: 40}, :close_connection)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "AMQP" <> <<0, 0, 9, 1>>)
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    assert {:ok, [_start], _} = Protocol.decode_frames(data)

    # send start-ok
    start_ok = Protocol.build_method_frame(0, 10, 11, <<0, 0, 0, 0>>)
    :ok = :gen_tcp.send(socket, Protocol.encode_frame(start_ok))
    {:ok, _tune_data} = :gen_tcp.recv(socket, 0, 1_000)

    tune_ok = Protocol.build_method_frame(0, 10, 31, <<0::16, 0::32, 0::16>>)
    :ok = :gen_tcp.send(socket, Protocol.encode_frame(tune_ok))

    open = Protocol.build_method_frame(0, 10, 40, Protocol.encode_shortstr("/") <> <<0::8>>)
    :ok = :gen_tcp.send(socket, Protocol.encode_frame(open))
    {:ok, _open_ok} = :gen_tcp.recv(socket, 0, 1_000)

    # now basic.publish which should trigger close_connection stub
    publish =
      Protocol.build_method_frame(
        1,
        60,
        40,
        <<0::8>> <> Protocol.encode_shortstr("") <> Protocol.encode_shortstr("queue")
      )

    :ok = :gen_tcp.send(socket, Protocol.encode_frame(publish))

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 500)

    calls = FauxMQ.calls(server)
    assert Enum.any?(calls, fn %{context: ctx} -> ctx.class_id == 60 and ctx.method_id == 40 end)

    :ok = FauxMQ.stop(server)
  end
end

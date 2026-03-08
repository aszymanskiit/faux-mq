defmodule FauxMQ.ServerHandshakeTest do
  use ExUnit.Case, async: false

  alias FauxMQ.Protocol

  test "performs minimal handshake with a TCP client" do
    {:ok, server} = FauxMQ.start_link(port: 0)
    port = FauxMQ.port(server)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, "AMQP" <> <<0, 0, 9, 1>>)

    assert {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    assert {:ok, [frame], _} = Protocol.decode_frames(data)

    assert frame.type == :method
    {10, 10, _} = Protocol.parse_method_payload(frame.payload)

    :gen_tcp.close(socket)
    :ok = FauxMQ.stop(server)
  end
end

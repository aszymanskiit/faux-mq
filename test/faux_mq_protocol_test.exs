defmodule FauxMQ.ProtocolTest do
  use ExUnit.Case, async: true

  alias FauxMQ.Protocol
  alias FauxMQ.Protocol.Frame

  test "encodes and decodes method frames roundtrip" do
    frame = %Frame{type: :method, channel: 1, payload: <<10::16, 10::16, "abc">>}

    bin = Protocol.encode_frame(frame)
    assert {:ok, [decoded], <<>>} = Protocol.decode_frames(bin)

    assert decoded.type == :method
    assert decoded.channel == 1
    assert decoded.payload == frame.payload
  end

  test "handles multiple frames in a single binary" do
    frame1 = %Frame{type: :heartbeat, channel: 0, payload: <<>>}
    frame2 = %Frame{type: :body, channel: 1, payload: "hello"}

    bin = Protocol.encode_frame(frame1) <> Protocol.encode_frame(frame2)

    assert {:ok, [d1, d2], <<>>} = Protocol.decode_frames(bin)
    assert d1.type == :heartbeat
    assert d2.type == :body
    assert d2.payload == "hello"
  end

  test "returns incomplete when not enough bytes" do
    frame = %Frame{type: :body, channel: 1, payload: "hello"}
    bin = Protocol.encode_frame(frame)

    <<partial::binary-size(5), _rest::binary>> = bin

    assert {:incomplete, _} = Protocol.decode_frames(partial)
  end
end

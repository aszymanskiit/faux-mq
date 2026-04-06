# FauxMQ

[![CI](https://github.com/aszymanskiit/faux-mq/actions/workflows/ci.yml/badge.svg)](https://github.com/aszymanskiit/faux-mq/actions/workflows/ci.yml)

FauxMQ is a **dummy AMQP 0-9-1 broker** implemented in Elixir/OTP.

It behaves like a real TCP AMQP endpoint from the client's perspective, while
giving tests **full control over the broker's behaviour**: handshakes, channels,
queues, exchanges, publishes, consumes, faults, timeouts and protocol-level
edge cases.

It is designed primarily for **integration testing ejabberd/XMPP** and other
systems that speak AMQP 0-9-1.

## Features

- **Real TCP AMQP 0-9-1 server** (listener, framing, handshake, channels)
- **Controllable mock/stub API** (`stub/3`, `expect/4`) for per-method behaviour
- **Call history** (`calls/1`) for assertions
- **Rules override defaults**: if a stub/expect matches an incoming method, that action runs; otherwise the built-in handler answers (handshake, channel lifecycle, in-memory queues/bindings, `basic.publish` / `basic.get` / `basic.consume` flow)
- **Per-server isolation**: each `FauxMQ.start_link/1` has its own listener, mock process, and broker state
- Intended as a **`mix` dependency** in test (or dev) environments

> Note: FauxMQ is **not a production broker**. It aims at protocol fidelity and
> excellent test ergonomics, not performance or completeness of broker semantics.

## Installation

Add FauxMQ to your `mix.exs` (requires Elixir ~> 1.13):

```elixir
def deps do
  [
    {:faux_mq, "~> 1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

The `:faux_mq` application starts a small supervision tree (including a `Registry` for internal use). **No TCP broker is listening until** you call `FauxMQ.start_link/1` (or add `FauxMQ.child_spec/1` to your own supervisor).

## Starting the server (`start_link/1`)

Relevant options:

| Option | Meaning |
|--------|--------|
| `:host` | Bind address as an IP tuple (default: `config :faux_mq, :default_host`, usually `{127, 0, 0, 1}`). |
| `:port` | **Not** the usual “`0` = OS ephemeral” shortcut by itself: `0` means “use `config :faux_mq, :default_port`”. The default config sets `default_port: 0`, which makes the OS choose a free port. If you set `default_port` to e.g. `5672`, then passing `port: 0` resolves to `5672`. Any other positive integer binds that port; if the port is already in use (`:eaddrinuse`), the server **falls back** to an ephemeral port. |

You can still use `FauxMQ.port/1` / `FauxMQ.endpoint/1` after start to read the actual port.

## Basic usage in ExUnit

```elixir
defmodule MyApp.AMQPTest do
  use ExUnit.Case, async: false

  test "uses FauxMQ as AMQP broker" do
    {:ok, server} = FauxMQ.start_link(port: 0)
    endpoint = FauxMQ.endpoint(server)

    # inject endpoint.host/endpoint.port into your system under test here

    # exercise your code ...

    calls = FauxMQ.calls(server)
    assert Enum.any?(calls, fn %{context: ctx} ->
             ctx.method_name == :basic_publish
           end)

    :ok = FauxMQ.stop(server)
  end
end
```

## Stubbing a single AMQP method

Example: when a client uses `basic.publish`, close the connection:

```elixir
{:ok, server} = FauxMQ.start_link(port: 0)

FauxMQ.stub(server, %{class_id: 60, method_id: 40}, :close_connection)
```

You can also match on `:method_name`, and optionally narrow by `:connection_id`, `:channel_id`, or a custom `{:predicate, fn ctx -> ... end}` (see types in `FauxMQ.Types`):

```elixir
FauxMQ.stub(server, %{method_name: :basic_publish}, :close_connection)
```

## Sequential responses

You can compose actions into sequences and delays:

```elixir
FauxMQ.expect(
  server,
  %{method_name: :basic_publish},
  2,
  {:sequence,
   [
     {:delay, 200, :no_reply},
     {:reply,
      {:frames,
       [
         FauxMQ.Protocol.build_connection_close(500, "first failure", 60, 40)
       ]}}
   ]}
)
```

This example:

- applies to the first two `basic.publish` calls
- waits 200ms
- sends a mocked `connection.close` error

## Fault injection

Simulate an authentication failure during handshake:

```elixir
FauxMQ.stub(
  server,
  %{method_name: :connection_start_ok},
  :protocol_error
)
```

Simulate a slow broker that never responds:

```elixir
FauxMQ.stub(
  server,
  %{method_name: :basic_publish},
  :no_reply
)
```

Simulate random connection drops:

```elixir
FauxMQ.stub(
  server,
  %{method_name: :basic_publish},
  :close_connection
)
```

## Publish / consume scenario

FauxMQ can push deliveries to clients, e.g. for `basic.consume` tests (the map keys match `FauxMQ.Types.push_delivery_spec/0`):

```elixir
delivery = %{
  channel_id: 1,
  consumer_tag: "ctag-1",
  exchange: "amq.direct",
  routing_key: "queue",
  payload: "hello",
  delivery_tag: 1,
  redelivered: false
}

FauxMQ.push_delivery(server, delivery)
```

The map may also include optional `header_payload` for content header bytes (see `push_delivery_spec` in `FauxMQ.Types`).

From the client's perspective this is indistinguishable from a normal broker
delivering a message after `basic.consume`.

## Pushing arbitrary server frames

For lower-level tests you can inject a raw frame (method/header/body/heartbeat) with `FauxMQ.push_frame/2`:

```elixir
FauxMQ.push_frame(server, %{
  type: :method,
  channel: 1,
  payload: <<...>>
})
```

See `push_frame_spec` / `frame_spec` in `FauxMQ.Types`.

## Using FauxMQ as ejabberd AMQP endpoint

In your integration test:

```elixir
{:ok, faux} = FauxMQ.start_link(port: 0)
endpoint = FauxMQ.endpoint(faux)

ejabberd_config =
  base_config()
  |> put_in([:amqp, :host], :inet.ntoa(endpoint.host) |> to_string())
  |> put_in([:amqp, :port], endpoint.port)

# start ejabberd using ejabberd_config
```

You can now run ejabberd's AMQP-based code against FauxMQ. Use `FauxMQ.stub/3`
and `FauxMQ.expect/4` to script failures, reconnections, nack/unroutable
behaviour, etc.

### Resetting state between tests

- **`FauxMQ.reset!/1`** — Clears **stub/expect rules and call history** on that server's mock process only. In-memory queues, bindings, and consumers on the broker side **stay**.
- **`FauxMQ.reset_test_broker_state/1`** — Clears mocks/history **and** in-memory queues, bindings, and consumers (TCP connections are not force-closed). Prefer this when published messages or queue state must not leak across examples in a long `mix test` run.

## Example integration test module

```elixir
defmodule MyApp.EjabberdIntegrationTest do
  use ExUnit.Case, async: false

  test "ejabberd publishes presence events over AMQP" do
    {:ok, faux} = FauxMQ.start_link(port: 0)
    endpoint = FauxMQ.endpoint(faux)

    # configure and start ejabberd using endpoint.host/endpoint.port

    # simulate XMPP activity that should trigger AMQP publish

    calls = FauxMQ.calls(faux)

    assert Enum.any?(calls, fn %{context: ctx} ->
             ctx.method_name == :basic_publish and ctx.channel_id == 1
           end)

    :ok = FauxMQ.stop(faux)
  end
end
```

## Debug logging

FauxMQ can emit verbose protocol and connection logs (handshake, frames, accept, lifecycle). They are **off by default**. To turn them on, set the `:debug` config to `true`.

**In config (e.g. `config/test.exs` or `config/dev.exs`):**

```elixir
config :faux_mq, debug: true
```

**At runtime (e.g. in `test_helper.exs` or a single test):**

```elixir
Application.put_env(:faux_mq, :debug, true)
```

When `debug` is `true`, logs use standard Elixir `Logger` at levels `:info`, `:debug`, `:warning`, `:error` (e.g. `[FauxMQ.Connection]`, `[FauxMQ.Server]`, `[FauxMQ.Protocol]`). When `false` (default), none of these internal logs are printed.

Other application env keys used by the library include `:default_host`, `:default_port`, and `:heartbeat_interval` (see `config/config.exs` in this repo).

**Example (tests with debug on only for one test file):**

```elixir
# test/my_amqp_test.exs
defmodule MyApp.MyAmqpTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:faux_mq, :debug, true)
    on_exit(fn -> Application.put_env(:faux_mq, :debug, false) end)
    :ok
  end

  test "something with AMQP" do
    # ... FauxMQ logs will appear
  end
end
```

## Running the project

```bash
mix deps.get
mix test
```

This repository does **not** include a `Dockerfile`; use a local Elixir/OTP install or any image that matches `mix.exs` (`elixir: "~> 1.13"`).

## CI

GitHub Actions workflows include:

- **CI** (`.github/workflows/ci.yml`): `mix format --check-formatted`, `mix credo --strict`, `mix test` on several OTP versions.
- **Dialyzer** (`.github/workflows/dialyzer.yml`): `mix dialyzer` (separate job with PLT caching).

## Limitations

- **Framing and parsing** follow AMQP 0-9-1; supported **methods and broker semantics** are those needed for integration-style testing (handshake, channel lifecycle, routing to in-memory queues, consumers, etc.), not full RabbitMQ parity.
- Routing is **simplified** (e.g. bindings and default-exchange behaviour are implemented in a minimal way compared to a real broker).
- Many methods can still be **intercepted** via `stub/3` and `expect/4` for fault injection or custom replies.
- The focus is on **protocol-level testing ergonomics** (mocks, history, pushed deliveries/frames), not throughput or production-grade queue semantics.

## License

MIT. See `LICENSE` file for details.


# FauxMQ

FauxMQ is a **dummy AMQP 0-9-1 broker** implemented in Elixir/OTP.

It behaves like a real TCP AMQP endpoint from the client's perspective, while
giving tests **full control over the broker's behaviour**: handshakes, channels,
queues, exchanges, publishes, consumes, faults, timeouts and protocol-level
edge cases.

It is designed primarily for **integration testing ejabberd/XMPP** and other
systems that speak AMQP 0-9-1.

## Features

- **Real TCP AMQP 0-9-1 server**
- **Controllable mock/stub API** for per-method behaviour
- **Call history** for assertions
- **Stateful or scripted modes** (mixed by default: mocks first, then defaults)
- **Per-server isolation**, many instances per test
- Designed to be run from tests via `mix deps` dependency

> Note: FauxMQ is **not a production broker**. It aims at protocol fidelity and
> excellent test ergonomics, not performance or completeness of broker semantics.

## Installation

Add FauxMQ to your `mix.exs` (requires Elixir ~> 1.13):

```elixir
def deps do
  [
    {:faux_mq, "~> 0.1"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

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

You can also match on `:method_name`:

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

From the client's perspective this is indistinguishable from a normal broker
delivering a message after `basic.consume`.

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
behaviour, etc. Use `FauxMQ.reset!/1` between tests to clear stubs and call history.

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

### Running in Docker

To run format, Credo, Dialyzer and tests in a clean environment:

```bash
docker build -t faux-mq .
docker run --rm faux-mq sh -c "mix format --check-formatted && mix credo --strict && mix dialyzer && mix test"
```

## CI

The repository includes a GitHub Actions workflow that runs:

- `mix format --check-formatted`
- `mix credo --strict`
- `mix dialyzer`
- `mix test`

## Publishing to Hex.pm

1. Ensure `mix.exs` contains correct `:package` and `:description` metadata.  
2. Build the package:

   ```bash
   MIX_ENV=prod mix hex.build
   ```

3. Publish the package:

   ```bash
   MIX_ENV=prod mix hex.publish
   ```

4. Tag the release in Git (use the same version as in `mix.exs`):

   ```bash
   git tag v0.1.0
   git push --tags
   ```

## Using as a GitHub dependency

In `mix.exs`:

```elixir
def deps do
  [
    {:faux_mq, git: "https://github.com/aszymanskiit/faux-mq.git", branch: "main"}
  ]
end
```

## Limitations

- FauxMQ implements the **full AMQP frame layer** and a **minimal handshake and
  channel lifecycle**.
- Many methods (e.g. `queue.declare`, `exchange.declare`, transactions, confirms)
  can be **mocked at protocol level**, but their **stateful broker semantics are
  intentionally simplified**.
- The focus is on: **protocol correctness, handshake, channel multiplexing,
  heartbeats, and powerful mock control**, rather than full RabbitMQ feature parity.

## License

MIT. See `LICENSE` file for details.


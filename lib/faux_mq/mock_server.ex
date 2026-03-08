defmodule FauxMQ.MockServer do
  @moduledoc """
  Per-server mock/expectation process.

  This process stores:

    * a list of rules (stubs and expectations)
    * a history of handled method calls
    * pending server-initiated deliveries and frames

  It is intentionally simple and focused on deterministic behaviour to make
  integration tests reliable and easy to reason about.
  """

  use GenServer

  alias FauxMQ.Types

  @type rule :: %{
          id: reference(),
          match: Types.match_spec(),
          action: Types.action_spec(),
          remaining: :infinity | non_neg_integer()
        }

  defstruct rules: [], calls: []

  @type t :: %__MODULE__{
          rules: [rule()],
          calls: [Types.call_record()]
        }

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(server) do
    GenServer.start_link(__MODULE__, server)
  end

  @impl true
  def init(_server) do
    {:ok, %__MODULE__{}}
  end

  @spec stub(pid(), Types.match_spec(), Types.action_spec()) :: :ok
  def stub(server, match, action) do
    GenServer.call(server_pid(server), {:stub, match, action})
  end

  @spec expect(pid(), Types.match_spec(), non_neg_integer(), Types.action_spec()) :: :ok
  def expect(server, match, count, action) do
    GenServer.call(server_pid(server), {:expect, match, count, action})
  end

  @spec push_delivery(pid(), Types.push_delivery_spec()) :: :ok
  def push_delivery(server, delivery) do
    GenServer.cast(server_pid(server), {:push_delivery, delivery})
  end

  @spec push_frame(pid(), Types.push_frame_spec()) :: :ok
  def push_frame(server, frame) do
    GenServer.cast(server_pid(server), {:push_frame, frame})
  end

  @spec calls(pid()) :: [Types.call_record()]
  def calls(server) do
    GenServer.call(server_pid(server), :calls)
  end

  @spec reset!(pid()) :: :ok
  def reset!(server) do
    GenServer.call(server_pid(server), :reset)
  end

  @doc """
  Records a call context, used by the connection process.
  """
  @spec record_call(pid(), Types.call_context()) :: :ok
  def record_call(mock_server, ctx) do
    GenServer.cast(mock_server, {:record_call, ctx})
  end

  @doc """
  Attempts to match a rule for the given call context.
  """
  @spec match_rule(pid(), Types.call_context()) :: {:action, Types.action_spec()} | :nomatch
  def match_rule(mock_server, ctx) do
    GenServer.call(mock_server, {:match, ctx})
  end

  @impl true
  def handle_call({:stub, match, action}, _from, state) do
    rule = %{
      id: make_ref(),
      match: match,
      action: action,
      remaining: :infinity
    }

    {:reply, :ok, %{state | rules: [rule | state.rules]}}
  end

  def handle_call({:expect, match, count, action}, _from, state) do
    rule = %{
      id: make_ref(),
      match: match,
      action: action,
      remaining: count
    }

    {:reply, :ok, %{state | rules: [rule | state.rules]}}
  end

  def handle_call(:calls, _from, state) do
    {:reply, Enum.reverse(state.calls), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  def handle_call({:match, ctx}, _from, state) do
    {matched, remaining_rules} =
      state.rules
      |> Enum.map_reduce([], fn rule, acc ->
        if matches_spec?(rule.match, ctx) do
          updated_rule =
            case rule.remaining do
              :infinity -> rule
              0 -> nil
              n -> %{rule | remaining: n - 1}
            end

          {rule, if(updated_rule, do: [updated_rule | acc], else: acc)}
        else
          {nil, [rule | acc]}
        end
      end)

    rules = Enum.reverse(remaining_rules)

    case Enum.find(matched, & &1) do
      nil ->
        {:reply, :nomatch, %{state | rules: rules}}

      rule ->
        {:reply, {:action, rule.action}, %{state | rules: rules}}
    end
  end

  @impl true
  def handle_cast({:record_call, ctx}, state) do
    record = %{context: ctx, timestamp: System.monotonic_time(:microsecond)}
    {:noreply, %{state | calls: [record | state.calls]}}
  end

  def handle_cast({:push_delivery, delivery}, state) do
    # broadcast to all connections via server registry
    send(self(), {:dispatch_push_delivery, delivery})
    {:noreply, state}
  end

  def handle_cast({:push_frame, frame}, state) do
    send(self(), {:dispatch_push_frame, frame})
    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info({:dispatch_push_delivery, delivery}, state) do
    Enum.each(Process.list(), fn pid ->
      send(pid, {:push_delivery, delivery})
    end)

    {:noreply, state}
  end

  def handle_info({:dispatch_push_frame, frame}, state) do
    Enum.each(Process.list(), fn pid ->
      send(pid, {:push_frame, frame})
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp matches_spec?(spec, ctx) do
    Enum.all?(spec, fn
      {:connection_id, :any} -> true
      {:connection_id, id} -> ctx.connection_id == id
      {:channel_id, :any} -> true
      {:channel_id, id} -> ctx.channel_id == id
      {:class_id, id} -> ctx.class_id == id
      {:method_id, id} -> ctx.method_id == id
      {:method_name, name} -> ctx.method_name == name
      {:predicate, fun} when is_function(fun, 1) -> fun.(ctx)
      _ -> true
    end)
  end

  defp server_pid(server) when is_pid(server), do: server
end

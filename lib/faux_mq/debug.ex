defmodule FauxMQ.Debug do
  @moduledoc """
  Debug logging controlled by the `:debug` config key.

  When `config :faux_mq, debug: true`, all FauxMQ internal logs (handshake,
  frames, connection lifecycle, server accept) are emitted. When `false`
  (default), they are suppressed.

  See the project README for usage.
  """

  require Logger

  @doc "Returns whether debug logging is enabled (config :faux_mq, :debug)."
  def enabled? do
    Application.get_env(:faux_mq, :debug, false)
  end

  @doc """
  Logs `message` at `level` only when `:faux_mq, :debug` is true.

  Levels: `:info`, `:debug`, `:warning`, `:error`.

  Use in FauxMQ modules to keep verbose protocol/connection logs off by default.
  """
  def log(level, message) when level in [:info, :debug, :warning, :error] do
    if enabled?() do
      apply(Logger, level, [message])
    end
  end
end

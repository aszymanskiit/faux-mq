import Config

config :faux_mq,
  default_host: {127, 0, 0, 1},
  default_port: 0,
  handshake_timeout: 5_000,
  heartbeat_interval: 0,
  # Set to true to enable verbose protocol/connection logs (handshake, frames, accept, etc.)
  debug: false

import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :slack_bot, SlackBotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "SqB9MHVzJ4qzqsud3z3Bw8HxS57ZxD+d9l+W/b0Iqru1aYt8hxvAP2B8ZskN8wlU",
  server: false

# In test we don't send emails
config :slack_bot, SlackBot.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

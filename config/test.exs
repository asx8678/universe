import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :universe, UniverseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Jy9+8PuVWCEijeoJQQ1u3po/Fv89e/3qAcftaiyxgnkZ3KV3nAIR3IxtZTqr6Y6n",
  server: false

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

# Tests never touch a real project's .universe/.
config :universe,
  project_dir: Path.expand("../tmp/test_project", __DIR__),
  log_raw_mcp: false

# Wake on unreported failures quickly so the attention rule is testable.
config :universe, attention_ms: 1_500

# The test project is shared by every test run; no daemon lock.
config :universe, lock: false

# Small enough that tests exercise archiving of settled workers.
config :universe, max_settled: 40

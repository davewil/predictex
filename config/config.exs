# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :predictex, :scopes,
  player: [
    default: true,
    module: Predictex.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:player, :id],
    schema_key: :player_id,
    schema_type: :id,
    schema_table: :players,
    test_data_fixture: Predictex.AccountsFixtures,
    test_setup_helper: :register_and_log_in_player
  ]

config :predictex,
  ecto_repos: [Predictex.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :predictex, PredictexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PredictexWeb.ErrorHTML, json: PredictexWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Predictex.PubSub,
  live_view: [signing_salt: "whN18wGO"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :predictex, Predictex.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  predictex: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  predictex: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Outbound link to the official FIFA Match Predictor (My Predictions dashboard).
# Overridable at runtime via FIFA_PREDICTOR_URL.
config :predictex, :fifa_predictor_url, "https://play.fifa.com/match-predictor/match"

# Oban — background jobs (result sync now; xox import later). Cron entries are added
# alongside their worker modules so Oban's Cron plugin can validate them at boot.
config :predictex, Oban,
  repo: Predictex.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Predictex.Workers.ResultSync},
       {"0 * * * *", Predictex.Workers.CohortSync},
       {"*/5 * * * *", Predictex.Workers.LiveScoreSync}
     ]}
  ]

config :fun_with_flags, :cache, enabled: true, ttl: 300

config :fun_with_flags, :persistence,
  adapter: FunWithFlags.Store.Persistent.Ecto,
  repo: Predictex.Repo

config :fun_with_flags, :cache_bust_notifications, enabled: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

import Config

# Configure node name to avoid conflicts with original TeslaMate
# Only configure in non-release mode to avoid conflicts with already started kernel application
unless System.get_env("RELEASE_MODE") do
  config :kernel,
    sync_nodes_optional: [:"teslamate-cn"],
    sync_nodes_timeout: 10_000
end

config :teslamate, TeslaMateWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  root: ".",
  server: true,
  version: Application.spec(:teslamate, :vsn)

config :logger,
  level: :info

config :logger, :console,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:car_id]

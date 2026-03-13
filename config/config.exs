import Config

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# Run "mix help config" for more information.
config :ex_linear, :api_url, "https://api.linear.app/graphql"

if config_env() == :test do
  config :ex_linear, :api_url, "https://api.linear.app/graphql"
end

# ExLinear

A Linear GraphQL client for Elixir. Fetch issues, run custom queries, and plug in your own config.

<div align="center">
  <img src="assets/linear-logo-light.png" alt="Linear" width="160" />
</div>

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:ex_linear, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get`.

## Configuration

Build config from options or from application config:

```elixir
# From options
config = ExLinear.Config.from_opts(
  api_key: System.get_env("LINEAR_API_KEY"),
  project_slug: "ENG",
  active_states: ["Todo", "In Progress"],
  assignee: "me"  # optional
)

# Or from application config (config.exs / runtime.exs)
config = ExLinear.Config.from_application()
```

In `config/runtime.exs` (or `config.exs`):

```elixir
config :ex_linear,
  api_key: System.get_env("LINEAR_API_KEY"),
  project_slug: "ENG",
  active_states: ["Todo", "In Progress"]
```

## Usage

**Fetch issues** for your project and states (with optional assignee filter):

```elixir
config = ExLinear.Config.from_opts(api_key: "...", project_slug: "ENG", active_states: ["Todo", "In Progress"])

{:ok, issues} = ExLinear.Client.fetch_candidate_issues(config)
# => list of %ExLinear.Issue{}
```

**Run any GraphQL** query or mutation:

```elixir
{:ok, body} = ExLinear.Client.graphql(config, "query { viewer { id } }", %{})
```

## License

Apache 2.0

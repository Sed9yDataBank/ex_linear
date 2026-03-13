defmodule ExLinear.Config do
  @moduledoc """
  Configuration for the Linear GraphQL client.

  Pass a struct or keyword list to `ExLinear.Client` functions. Required fields
  depend on the operation: `api_key` and `endpoint` for GraphQL calls;
  `project_slug` and `active_states` for `fetch_candidate_issues/1` and
  `fetch_issues_by_states/2`.

  ## Examples

      # From keyword list (e.g. from Application config)
      config = ExLinear.Config.from_opts(
        api_key: System.get_env("LINEAR_API_KEY"),
        endpoint: ExLinear.Config.default_endpoint(),
        project_slug: "ENG",
        active_states: ["Todo", "In Progress"],
        assignee: "me"
      )

      # From application config
      config = ExLinear.Config.from_application()

  """

  defstruct [
    :api_key,
    :endpoint,
    :project_slug,
    :active_states,
    :assignee
  ]

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          endpoint: String.t() | nil,
          project_slug: String.t() | nil,
          active_states: [String.t()] | nil,
          assignee: String.t() | nil
        }

  @default_endpoint "https://api.linear.app/graphql"

  @doc """
  Returns the default Linear GraphQL endpoint URL.
  """
  @spec default_endpoint() :: String.t()
  def default_endpoint, do: @default_endpoint

  @doc """
  Builds a config struct from a keyword list.

  Application config (`:ex_linear`) may also include:
  - `:request_fun` – optional 3-arity `(config, payload, headers) -> result` used by the client
    for all GraphQL requests. When set (e.g. in tests), it replaces the default HTTP implementation.

  Options:
  - `:api_key` – Linear API token (required for API calls)
  - `:endpoint` – GraphQL endpoint (default: `default_endpoint/0` or `:ex_linear` `:api_url`)
  - `:project_slug` – Project slug for issue listing
  - `:active_states` – List of state names for candidate issues
  - `:assignee` – Assignee filter: `"me"` (viewer), user ID, or `nil` for no filter
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts \\ []) when is_list(opts) do
    endpoint =
      Keyword.get_lazy(opts, :endpoint, fn ->
        Application.get_env(:ex_linear, :api_url, @default_endpoint)
      end)

    active_states = Keyword.get(opts, :active_states)
    active_states = if is_list(active_states), do: active_states, else: nil

    %__MODULE__{
      api_key: Keyword.get(opts, :api_key),
      endpoint: endpoint,
      project_slug: Keyword.get(opts, :project_slug),
      active_states: active_states,
      assignee: Keyword.get(opts, :assignee)
    }
  end

  @doc """
  Builds a config struct from application config.

  Reads `:ex_linear` application env: `:api_key`, `:api_url` (as endpoint),
  `:project_slug`, `:active_states`, `:assignee`.
  """
  @spec from_application() :: t()
  def from_application do
    env = Application.get_all_env(:ex_linear)

    from_opts(
      api_key: Keyword.get(env, :api_key),
      endpoint: Keyword.get(env, :api_url),
      project_slug: Keyword.get(env, :project_slug),
      active_states: Keyword.get(env, :active_states),
      assignee: Keyword.get(env, :assignee)
    )
  end

  @doc """
  Returns the GraphQL endpoint URL for this config.
  """
  @spec endpoint(t()) :: String.t()
  def endpoint(%__MODULE__{endpoint: url}) when is_binary(url), do: url
  def endpoint(_), do: Application.get_env(:ex_linear, :api_url, @default_endpoint)
end

defmodule ExLinear.Client do
  @moduledoc """
  Linear GraphQL client: queries, pagination, and mutations with explicit config.

  All functions that call the API take an `ExLinear.Config` struct (or options
  passed through `ExLinear.Config.from_opts/1`) as the first argument.
  """

  require Logger
  alias ExLinear.{Config, Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query IssuesByProjectAndStates($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @viewer_query """
  query ViewerCurrent {
    viewer {
      id
    }
  }
  """

  @doc """
  Low-level GraphQL request. Uses `config` for API key and endpoint.

  The HTTP implementation is taken from `Application.get_env(:ex_linear, :request_fun)`
  when set (e.g. in tests); otherwise the default Req-based implementation is used.

  Options:
  - `:operation_name` – optional operation name for the request
  """
  @spec graphql(Config.t() | keyword(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def graphql(config, query, variables \\ %{}, opts \\ [])
      when (is_struct(config, Config) or is_list(config)) and is_binary(query) and
             is_map(variables) and is_list(opts) do
    c = normalize_config(config)
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))

    with {:ok, headers} <- graphql_headers(c),
         {:ok, %{status: 200, body: body}} <- request_impl().(c, payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc """
  Fetches candidate issues for the configured project and active states, with optional assignee filter.
  """
  @spec fetch_candidate_issues(Config.t() | keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(config) do
    c = normalize_config(config)
    project_slug = c.project_slug
    active_states = c.active_states || []

    cond do
      is_nil(c.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(c) do
          do_fetch_by_states(c, project_slug, active_states, assignee_filter)
        end
    end
  end

  defp normalize_config(opts) when is_list(opts), do: Config.from_opts(opts)
  defp normalize_config(%Config{} = c), do: c

  defp request_impl do
    Application.get_env(:ex_linear, :request_fun, &post_graphql_request/3)
  end

  defp do_fetch_by_states(c, project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(c, project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(
         c,
         project_slug,
         state_names,
         assignee_filter,
         after_cursor,
         acc_issues
       ) do
    with {:ok, body} <-
           graphql(c, @query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(
            c,
            project_slug,
            state_names,
            assignee_filter,
            next_cursor,
            updated_acc
          )

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues),
    do: Enum.reverse(acc_issues)

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)
    if trimmed == "", do: payload, else: Map.put(payload, "operationName", trimmed)
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body = response |> Map.get(:body) |> summarize_error_body()
    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(%Config{api_key: nil}), do: {:error, :missing_linear_api_token}

  defp graphql_headers(%Config{api_key: token}) do
    {:ok,
     [
       {"Authorization", token},
       {"Content-Type", "application/json"}
     ]}
  end

  defp post_graphql_request(%Config{} = c, payload, headers) do
    Req.post(Config.endpoint(c),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <-
           decode_linear_response(
             %{"data" => %{"issues" => %{"nodes" => nodes}}},
             assignee_filter
           ) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter),
    do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assignee_matches_filter: assignee_matches_filter?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assignee_matches_filter?(_assignee, nil), do: true

  defp assignee_matches_filter?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assignee_matches_filter?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter(%Config{assignee: nil}), do: {:ok, nil}
  defp routing_assignee_filter(%Config{} = c), do: build_assignee_filter(c, c.assignee)

  defp build_assignee_filter(c, assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(c)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp build_assignee_filter(_c, _), do: {:ok, nil}

  defp resolve_viewer_assignee_filter(c) do
    case graphql(c, @viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil -> {:error, :missing_linear_viewer_identity}
          viewer_id -> {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end

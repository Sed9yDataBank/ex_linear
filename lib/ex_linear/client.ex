defmodule ExLinear.Client do
  @moduledoc """
  Linear GraphQL client: queries, pagination, and mutations with explicit config.

  All functions that call the API take an `ExLinear.Config` struct (or options
  passed through `ExLinear.Config.from_opts/1`) as the first argument.
  """

  require Logger
  alias ExLinear.Config

  @max_error_body_log_bytes 1_000

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

  defp request_impl do
    Application.get_env(:ex_linear, :request_fun, &post_graphql_request/3)
  end

  defp normalize_config(opts) when is_list(opts), do: Config.from_opts(opts)
  defp normalize_config(%Config{} = c), do: c

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
end

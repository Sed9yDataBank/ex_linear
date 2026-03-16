defmodule ExLinear.Issue.CreateInput do
  @moduledoc """
  Input for creating a Linear issue via `issueCreate` mutation.

  Struct fields use snake_case; they are converted to GraphQL's camelCase in the
  variable map. Only `team_id` is required by the API; all other fields are optional.
  """

  defstruct [
    :team_id,
    :title,
    :description,
    :project_id,
    :state_id,
    :assignee_id,
    :priority,
    :parent_id,
    :cycle_id,
    label_ids: nil
  ]

  @type t :: %__MODULE__{
          team_id: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          project_id: String.t() | nil,
          state_id: String.t() | nil,
          assignee_id: String.t() | nil,
          priority: integer() | nil,
          parent_id: String.t() | nil,
          cycle_id: String.t() | nil,
          label_ids: [String.t()] | nil
        }

  @doc """
  Converts the struct to a map suitable for the GraphQL `input` variable.

  Keys are camelCase; only non-nil values are included. Used by the client when
  calling the `issueCreate` mutation.
  """
  @spec to_input_map(t()) :: %{String.t() => term()}
  def to_input_map(%__MODULE__{} = input) do
    []
    |> maybe_put("teamId", input.team_id)
    |> maybe_put("title", input.title)
    |> maybe_put("description", input.description)
    |> maybe_put("projectId", input.project_id)
    |> maybe_put("stateId", input.state_id)
    |> maybe_put("assigneeId", input.assignee_id)
    |> maybe_put("priority", input.priority)
    |> maybe_put("parentId", input.parent_id)
    |> maybe_put("cycleId", input.cycle_id)
    |> maybe_put("labelIds", input.label_ids)
    |> Map.new()
  end

  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, key, value), do: [{key, value} | acc]
end

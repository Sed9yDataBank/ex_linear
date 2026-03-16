defmodule ExLinear.Issue.UpdateInput do
  @moduledoc """
  Input for partially updating a Linear issue via `issueUpdate` mutation.

  Struct fields use snake_case; they are converted to GraphQL's camelCase in the
  variable map. All fields are optional; only non-nil values are sent (omit = leave unchanged).
  Use for assigning (assignee_id), changing state (state_id), description, priority, etc.
  """

  defstruct [
    :assignee_id,
    :state_id,
    :description,
    :priority,
    :project_id,
    :cycle_id,
    :parent_id,
    :title,
    :due_date,
    label_ids: nil
  ]

  @type t :: %__MODULE__{
          assignee_id: String.t() | nil,
          state_id: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          project_id: String.t() | nil,
          cycle_id: String.t() | nil,
          parent_id: String.t() | nil,
          title: String.t() | nil,
          due_date: String.t() | nil,
          label_ids: [String.t()] | nil
        }

  @doc """
  Converts the struct to a map suitable for the GraphQL `input` variable.

  Keys are camelCase; only non-nil values are included (partial update).
  Used by the client when calling the `issueUpdate` mutation.
  """
  @spec to_input_map(t()) :: %{String.t() => term()}
  def to_input_map(%__MODULE__{} = input) do
    []
    |> maybe_put("assigneeId", input.assignee_id)
    |> maybe_put("stateId", input.state_id)
    |> maybe_put("description", input.description)
    |> maybe_put("priority", input.priority)
    |> maybe_put("projectId", input.project_id)
    |> maybe_put("cycleId", input.cycle_id)
    |> maybe_put("parentId", input.parent_id)
    |> maybe_put("title", input.title)
    |> maybe_put("dueDate", input.due_date)
    |> maybe_put("labelIds", input.label_ids)
    |> Map.new()
  end

  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, key, value), do: [{key, value} | acc]
end

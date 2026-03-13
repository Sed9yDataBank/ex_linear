defmodule ExLinear.Issue do
  @moduledoc """
  Normalized Linear issue representation returned by the client.

  Note: `assignee_matches_filter` is **not** from Linear's API. The client sets it when
  you use an assignee filter in config (`assignee: "me"` or a user ID): it is
  `true` when the issue's assignee matches that filter (or when no filter is set),
  and `false` otherwise. Use it to quickly filter "issues assigned to me" without
  comparing `assignee_id` yourself.
  """

  @type blocker :: %{id: String.t(), identifier: String.t() | nil, state: String.t() | nil}

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assignee_matches_filter: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          blocked_by: [blocker()],
          labels: [String.t()],
          assignee_matches_filter: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Returns the list of label names on the issue (lowercased).
  """
  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}), do: labels
end
